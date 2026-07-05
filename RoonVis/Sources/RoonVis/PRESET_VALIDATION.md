# Preset Validation

Set `RoonVisValidatePresets` to `YES` in `Sources/RoonVis/Info.plist`, build and launch the tvOS Simulator app, then inspect the generated report:

```sh
xcrun simctl get_app_container booted local.roon-vis.gate-step-a data
```

The report is `Documents/preset_validation.txt` inside that container. Set `RoonVisValidatePresets` back to `NO` for normal app behavior.
