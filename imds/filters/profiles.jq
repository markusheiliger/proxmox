[
  (.tags // "")
  | if type == "string" then . else error("metadata tags must be a string") end
  | split(";")[]
  | select(startswith("profile-"))
  | if test("^profile-[a-z0-9_]+-[a-z0-9_]+$")
    then capture("^profile-(?<group>[a-z0-9_]+)-(?<name>[a-z0-9_]+)$")
    else error("invalid profile tag")
    end
]
| sort_by(.group)
| if any(group_by(.group)[]; length != 1)
  then error("multiple profile tags for one group")
  else map("\(.group)-\(.name)") | sort
  end