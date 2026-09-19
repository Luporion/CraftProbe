# Releasing CraftProbe

Example for version `0.1.1`:

```powershell
git add .
git commit -m "Prepare CraftProbe v0.1.1"
git push

git tag -a v0.1.1 -m "CraftProbe v0.1.1"
git push origin v0.1.1
```

Then create a GitHub Release from tag `v0.1.1` and attach the release ZIP.

Before tagging a release:

- run `CraftProbe.cmd` on at least one real modded profile;
- verify that the Explorer-style profile picker opens when no path is supplied;
- verify that both Session and Performance archives are produced as expected;
- verify that `VERSION`, `CHANGELOG.md` and the PowerShell version constants match;
- inspect the ZIP for personal paths, logs or test artifacts before publishing it.
