@{
    # These are scripts, not a module. quick-clean.ps1 has -DryRun and the installer
    # asks before it changes anything, so per-function ShouldProcess adds nothing.
    ExcludeRules = @('PSUseShouldProcessForStateChangingFunctions')
}
