# Releasing CraftProbe

1. Update `VERSION`, `CHANGELOG.md` and README if needed.
2. Run the regression checklist in [`TESTING.md`](TESTING.md), especially with a Minecraft profile path containing spaces.
3. Confirm `CAPTURE_STATUS.json` does not hide failed expected artifacts.
4. Commit and push:

```powershell
git add .
git commit -m "Prepare CraftProbe vX.Y.Z"
git push
```

5. Tag only after the smoke test is clean:

```powershell
git tag -a vX.Y.Z -m "CraftProbe vX.Y.Z"
git push origin vX.Y.Z
```

6. Create the GitHub release from that tag and attach the portable `CraftProbe-vX.Y.Z.zip`.
