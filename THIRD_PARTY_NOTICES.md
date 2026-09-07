# Platform dependencies and notices

Battery Flow uses no external Swift package dependencies or vendored libraries, fonts, or image assets. The Python and shell tools use platform-provided standard libraries and commands.

The application links Apple platform frameworks including SwiftUI, AppKit, Charts, Combine, IOKit, ServiceManagement, and QuartzCore. These frameworks are provided by the operating system and SDK; they are not redistributed as source in this repository or relicensed by the project's source license.

Interface symbols are requested by name from macOS SF Symbols at runtime. No exported SF Symbols artwork or font files are included. Apple documents system symbols as supported [menu-bar item labels](https://developer.apple.com/documentation/swiftui/menubarextra).

Apple's [SF Symbols usage guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) includes restrictions on using symbols as app icons, logos, or trademarks, and on modifying symbols representing Apple products or features. A future standalone app icon or project logo must use artwork with suitable independent rights. This repository does not grant rights to Apple artwork, names, or trademarks.

New dependencies or copied material must be reviewed for license compatibility and attributed here as appropriate.
