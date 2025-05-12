# Clean files - Chromium
```
for files in $(find *chrome://version profile*/ -maxdepth 1)
do
mkdir -p ./destFolder/
echo $files | grep -Ei network | xargs -I% mv -fv % ./destFolder/
echo $files | grep -Ei login | xargs -I% mv -fv % ./destFolder/
echo $files | grep -Ei vault | xargs -I% mv -fv % ./destFolder/
echo $files | grep -Ei database | xargs -I% mv -fv % ./destFolder/
echo $files | grep -Ei sync | xargs -I% mv -fv % ./destFolder/
echo $files | grep -Ei account | xargs -I% mv -fv % ./destFolder/
echo $files | grep -Ei extension | xargs -I% mv -fv % ./destFolder/
done
```

---
# Clean files - Firefox
```
for files in $(find *Firefox profile*/ -maxdepth 1)
do
mkdir -p ../destFolder/
echo $files | grep -Ei cookies | xargs -I% mv -fv % ../destFolder/
echo $files | grep -Ei addon | xargs -I% mv -fv % ../destFolder/
echo $files | grep -Ei extension | xargs -I% mv -fv % ../destFolder/
echo $files | grep -Ei storage | xargs -I% mv -fv % ../destFolder/
echo $files | grep -Ei settings | xargs -I% mv -fv % ../destFolder/
echo $files | grep -Ei prefs | xargs -I% mv -fv % ../destFolder/
done
```