cask "cellkeep" do
  version "1.4.2"
  sha256 "65bec5d2105d5823bf24d5a0ab77780799c73f0bf40bf5eaabe8d9d09d5c1691"

  url "https://github.com/berkinefeavci/healthy-battery/releases/download/v#{version}/Cellkeep-#{version}.dmg"
  name "Healthy Battery"
  desc "Menu bar charge limiter and battery monitor"
  homepage "https://github.com/berkinefeavci/healthy-battery"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Cellkeep.app"

  # `brew upgrade` runs `uninstall` too, so it only quits the app. Removing the root helpers there
  # would ask for a password on every upgrade and turn off the LED and power-mode helpers.
  uninstall quit: "io.github.berkinefeavci.cellkeep"

  zap launchctl: [
        "io.github.berkinefeavci.cellkeep.chargeinhibit",
        "io.github.berkinefeavci.cellkeep.led",
        "io.github.berkinefeavci.cellkeep.powermode",
      ],
      delete:    [
        "/Library/Application Support/CellkeepChargeInhibit",
        "/Library/Application Support/CellkeepLED",
        "/Library/Application Support/CellkeepPowerMode",
        "/Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.chargeinhibit.plist",
        "/Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.led.plist",
        "/Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.powermode.plist",
        "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.chargeinhibit",
        "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led",
        "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode",
      ],
      trash:     [
        "~/Library/Application Support/Cellkeep",
        "~/Library/Preferences/io.github.berkinefeavci.cellkeep.plist",
      ]

  caveats <<~EOS
    Upgrades keep Healthy Battery's helpers. To remove them, use Settings → General → Uninstall
    Healthy Battery first, or `brew uninstall --zap --cask cellkeep`.
    Healthy Battery's charge limit uses macOS's own charge-limit setting, which stays as it was
    after uninstalling. Reset it in System Settings → Battery if you want to.
  EOS
end
