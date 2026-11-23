function matcolor --description 'R G B of a color from the current wallpaper: matcolor [ROLE] [SCHEME]'
    # ROLE:   primary (default), source_color, surface, surface_container_high,
    #         tertiary, ... (`noctalia theme ~/.cache/current-wallpaper --dark | palette-view`
    #         shows them all)
    # SCHEME: Noctalia's schemes: tonal-spot, content, fruit-salad, rainbow,
    #         monochrome (the Material ones, with or without "m3-"), and
    #         vibrant, faithful, soft, muted, dysfunctional.
    #         Default: the scheme set for this wallpaper in
    #         ~/.config/noctalia/wallpaper-schemes.conf, else Noctalia's
    #         current scheme, else tonal-spot.
    # Colors come from Noctalia itself (the same generator the desktop uses);
    # matugen is only a fallback for the Material schemes.
    set -l role primary
    set -q argv[1]; and set role $argv[1]
    set -l scheme
    if set -q argv[2]
        set scheme $argv[2]
    else
        set scheme (__matcolor_scheme)
    end
    # Noctalia's names: the Material schemes carry an "m3-" prefix
    switch $scheme
        case vibrant faithful soft muted dysfunctional 'm3-*'
        case '*'
            set scheme m3-$scheme
    end

    set -l json
    if command -q noctalia
        set json (noctalia theme ~/.cache/current-wallpaper --dark --scheme $scheme 2>/dev/null </dev/null | string join '')
    end
    if test -z "$json"; and string match -q -- 'm3-*' $scheme; and command -q matugen
        # fallback: matugen knows the Material schemes (without the prefix)
        set -l pick
        matugen image --help 2>&1 | string match -q -- '*--source-color-index*'; and set pick --source-color-index 0
        set json (matugen image ~/.cache/current-wallpaper $pick --dry-run --json hex \
            -t scheme-(string replace -- 'm3-' '' $scheme) 2>/dev/null </dev/null | string join '')
    end

    set -l hex (string match -r -g "\"$role\"[^#]*#([0-9A-Fa-f]{6})" -- $json)[1]
    if test -z "$hex"
        echo "matcolor: no '$role' color found (scheme $scheme)" >&2
        return 1
    end
    # One value per line, so (matcolor) expands to three arguments
    math 0x(string sub -s 1 -l 2 $hex)
    math 0x(string sub -s 3 -l 2 $hex)
    math 0x(string sub -s 5 -l 2 $hex)
end

# The Noctalia scheme for the current wallpaper (prints e.g. "faithful")
function __matcolor_scheme
    set -l config_home ~/.config
    set -q XDG_CONFIG_HOME; and test -n "$XDG_CONFIG_HOME"; and set config_home $XDG_CONFIG_HOME
    set -l state_home ~/.local/state
    set -q XDG_STATE_HOME; and test -n "$XDG_STATE_HOME"; and set state_home $XDG_STATE_HOME

    # 1. The wallpaper's rule in wallpaper-schemes.conf (first match wins)
    set -l map $config_home/noctalia/wallpaper-schemes.conf
    set -l wall (path resolve ~/.cache/current-wallpaper)
    set -l name (path basename -- $wall)
    if test -r $map
        for line in (cat $map)
            set -l parts (string match -r -g '^\s*([^#\s]\S*)\s+(\S+)' -- $line)
            test (count $parts) -eq 2; or continue
            if string match -q -- $parts[1] $name; or string match -q -- $parts[1] $wall
                echo $parts[2]
                return
            end
        end
    end

    # 2. Otherwise Noctalia's current setting
    for f in $state_home/noctalia/settings.toml $config_home/noctalia/config.toml
        test -r $f; or continue
        set -l s (awk -F= '/^\[/ {t = ($0 ~ /^\[theme\][[:space:]]*$/)}
            t && /^[[:space:]]*wallpaper_scheme[[:space:]]*=/ {
                v = $2; gsub(/[[:space:]"]/, "", v); print v; exit }' $f)
        if test -n "$s"
            echo $s
            return
        end
    end
    echo m3-tonal-spot
end
