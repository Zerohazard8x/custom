#!/bin/sh

rm -f temp.txt

maintain() {
    grep '$all' "$1" >> temp.txt
    grep '$document' "$1" >> temp.txt
    grep '^[.|]' "$1" | grep '[.^]$' >> temp.txt
    awk '!/$/ && !/|/ && !/#/' \"$1" >> temp.txt
    rm -f "$1"
}

aria2c -R --allow-overwrite=true --disable-ipv6 "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-online.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/resource-abuse.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/lan-block.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-cookies.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-others.txt"

aria2c -R --allow-overwrite=true --disable-ipv6 "https://easylist.to/easylist/easylist.txt"
aria2c -R --allow-overwrite=true --disable-ipv6 "https://easylist.to/easylist/easyprivacy.txt"

aria2c -R --allow-overwrite=true --disable-ipv6 "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&mimetype=plaintext" -o yoyo.txt
aria2c -R --allow-overwrite=true --disable-ipv6 "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_14_Annoyances/filter.txt" -o adguard_annoyances.txt

maintain "adguard_annoyances.txt"
maintain "annoyances.txt"
maintain "badware.txt"
maintain "easylist.txt"
maintain "easyprivacy.txt"
maintain "filters.txt"
maintain "privacy.txt"
maintain "quick-fixes.txt"
maintain "resource-abuse.txt"
maintain "unbreak.txt"
maintain "urlhaus-filter-online.txt"
maintain "yoyo.txt"

< "temp.txt" awk '!/*/ && !/!/' | sed 's/www\.//g; s/http:\/\///g; s/https:\/\///g' | sort -u > base.txt
rm -f "temp.txt"