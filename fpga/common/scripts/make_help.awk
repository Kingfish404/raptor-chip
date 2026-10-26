# Print `make help` for a native board from its Makefiles.
# Sections:  a "# =====" line followed by "# Title".
# Targets:   "name: ## description".
# Variables: "NAME ?= default ## description"; a later file overrides the
#            default, so pass the board Makefile last.
BEGIN { print "Usage: make <target> [VAR=value ...]" }

/^# =+$/ { after_banner = 1; next }
after_banner && /^# / { section = substr($0, 3); after_banner = 0; next }
{ after_banner = 0 }

/^[a-z][a-z0-9-]*:.*## / {
    if (section != printed) {
        printf "\n%s:\n", section
        printed = section
    }
    name = $0; sub(/:.*/, "", name)
    text = $0; sub(/.*## /, "", text)
    printf "  %-20s %s\n", name, text
    next
}

/^[A-Z][A-Z0-9_]* *\?=.*## / {
    name = $0; sub(/ *\?=.*/, "", name)
    value = $0; sub(/^[^?]*\?= */, "", value); sub(/ *##.*/, "", value)
    text = $0; sub(/.*## /, "", text)
    if (!(name in description))
        order[++count] = name
    description[name] = text
    default_value[name] = value
}

END {
    print "\nVariables (default in brackets):"
    for (i = 1; i <= count; i++) {
        name = order[i]
        value = default_value[name] == "" ? "" : " [" default_value[name] "]"
        printf "  %-20s %s%s\n", name, description[name], value
    }
}
