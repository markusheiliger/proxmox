import os
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ddns_update import (  # noqa: E402
    ApiError,
    Config,
    ConfigurationError,
    health_is_fresh,
    reconcile_dns,
    reconcile_once,
    select_global_ipv6,
    write_health,
)


def valid_env(health_file: str = "/tmp/ddns-health") -> dict[str, str]:
    return {
        "UDM_URL": "https://udm.example.test",
        "UDM_API_KEY": "udm-secret",
        "UNIFI_SITE": "default",
        "UDM_TLS_VERIFY": "false",
        "DNSIMPLE_ZONE": "example.test",
        "DNSIMPLE_RECORD": "gateway",
        "DNSIMPLE_API_ACCESS_TOKEN": "dns-secret",
        "DNSIMPLE_ACCOUNT_ID": "1234",
        "DNS_TTL": "300",
        "UPDATE_INTERVAL": "300",
        "HEALTH_FILE": health_file,
    }


class ConfigTests(unittest.TestCase):
    def test_valid_environment(self):
        config = Config.from_env(valid_env())
        self.assertFalse(config.udm_tls_verify)
        self.assertEqual(config.dns_ttl, 300)

    def test_rejects_invalid_values(self):
        cases = {
            "UDM_URL": "http://udm.example.test",
            "UDM_TLS_VERIFY": "perhaps",
            "DNSIMPLE_RECORD": "bad_record",
            "DNS_TTL": "30",
            "UPDATE_INTERVAL": "abc",
        }
        for key, value in cases.items():
            with self.subTest(key=key):
                env = valid_env()
                env[key] = value
                with self.assertRaises(ConfigurationError):
                    Config.from_env(env)


class AddressTests(unittest.TestCase):
    def test_selects_one_global_address_from_nested_wan(self):
        payload = {
            "data": [
                {"wan1": {"ipv6": ["fe80::1", "fd00::1"]}},
                {"nested": {"wan1": {"ipv6": ["2a00:6020:5880::a22"]}}},
            ]
        }
        self.assertEqual(select_global_ipv6(payload), "2a00:6020:5880::a22")

    def test_rejects_missing_or_ambiguous_global_address(self):
        with self.assertRaises(ApiError):
            select_global_ipv6({"data": [{"wan1": {"ipv6": ["fe80::1"]}}]})
        with self.assertRaises(ApiError):
            select_global_ipv6(
                {
                    "data": [
                        {
                            "wan1": {
                                "ipv6": ["2a00:6020::1", "2a00:6020::2"]
                            }
                        }
                    ]
                }
            )


class DnsTests(unittest.TestCase):
    def setUp(self):
        self.config = Config.from_env(valid_env())

    def requester_for_records(self, records):
        calls = []

        def requester(method, url, headers, payload=None, context=None):
            calls.append((method, url, payload))
            if method == "GET":
                return {"data": records}
            return {"data": {}}

        return requester, calls

    def test_create_update_and_noop_decisions(self):
        requester, calls = self.requester_for_records([])
        self.assertEqual(
            reconcile_dns(self.config, "2a00:6020::1", requester=requester),
            "create",
        )
        self.assertEqual(calls[-1][0], "POST")

        requester, calls = self.requester_for_records(
            [{"id": 7, "type": "AAAA", "name": "gateway", "content": "::1", "ttl": 60}]
        )
        self.assertEqual(
            reconcile_dns(self.config, "2a00:6020::1", requester=requester),
            "update",
        )
        self.assertEqual(calls[-1][0], "PATCH")

        requester, calls = self.requester_for_records(
            [
                {
                    "id": 7,
                    "type": "AAAA",
                    "name": "gateway",
                    "content": "2a00:6020::1",
                    "ttl": 300,
                }
            ]
        )
        self.assertEqual(
            reconcile_dns(self.config, "2a00:6020::1", requester=requester),
            "noop",
        )
        self.assertEqual(len(calls), 1)

    def test_duplicate_records_fail_closed(self):
        requester, _ = self.requester_for_records(
            [
                {"id": 1, "type": "AAAA", "name": "gateway"},
                {"id": 2, "type": "AAAA", "name": "gateway"},
            ]
        )
        with self.assertRaises(ApiError):
            reconcile_dns(self.config, "2a00:6020::1", requester=requester)

    def test_dry_run_does_not_write(self):
        requester, calls = self.requester_for_records([])
        self.assertEqual(
            reconcile_dns(
                self.config, "2a00:6020::1", dry_run=True, requester=requester
            ),
            "create",
        )
        self.assertEqual([call[0] for call in calls], ["GET"])

    def test_account_id_can_come_from_whoami(self):
        env = valid_env()
        env.pop("DNSIMPLE_ACCOUNT_ID")
        config = Config.from_env(env)
        calls = []

        def requester(method, url, headers, payload=None, context=None):
            calls.append(url)
            if url.endswith("/whoami"):
                return {"data": {"account": {"id": 456}}}
            return {"data": []}

        self.assertEqual(
            reconcile_dns(config, "2a00:6020::1", True, requester), "create"
        )
        self.assertIn("/v2/456/zones/", calls[-1])


class HealthTests(unittest.TestCase):
    def test_health_is_written_only_for_non_dry_run_success(self):
        with tempfile.TemporaryDirectory() as directory:
            health_file = Path(directory) / "last-success"
            config = Config.from_env(valid_env(str(health_file)))

            def requester(method, url, headers, payload=None, context=None):
                if "stat/device" in url:
                    return {"data": [{"wan1": {"ipv6": ["2a00:6020::1"]}}]}
                return {"data": []}

            action, _ = reconcile_once(config, True, requester)
            self.assertEqual(action, "create")
            self.assertFalse(health_file.exists())
            reconcile_once(config, False, requester)
            self.assertTrue(health_file.exists())

    def test_health_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            health_file = Path(directory) / "last-success"
            config = Config.from_env(valid_env(str(health_file)))
            write_health(health_file, 1000)
            self.assertTrue(health_is_fresh(config, 1500))
            self.assertFalse(health_is_fresh(config, 2000))


if __name__ == "__main__":
    unittest.main()