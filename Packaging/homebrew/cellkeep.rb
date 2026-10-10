cask "cellkeep" do
  version "1.4.1"
  sha256 "a5adeb88a54655d0d48c1635b6951d26daac41b3b0f43899bd71e79ec3857da6"

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
    Upgrades keep Cellkeep's helpers. To remove them, use Settings → General → Uninstall
    Cellkeep first, or `brew uninstall --zap --cask cellkeep`.
    Cellkeep's charge limit uses macOS's own charge-limit setting, which stays as it was
    after uninstalling. Reset it in System Settings → Battery if you want to.
  EOS
end
