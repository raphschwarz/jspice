// The extension's process starts in NSExtensionMain (its entry point, set in Package.swift), which loads the principal
// class its Info.plist names: AudioUnitViewController. Nothing runs from here; the reference keeps the class linked.
_ = AudioUnitViewController.self
