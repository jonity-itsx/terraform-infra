# Delad TFLint-konfiguration för båda root-modulerna, team/ och
# team/bootstrap/. Workflowet pekar hit via TFLINT_CONFIG_FILE, eftersom
# TFLint annars letar efter en egen .tflint.hcl i varje katalog den körs i.

config {
  call_module_type = "local"
}

# Ingår i TFLint, kräver ingen nedladdning.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Google-specifika regler: ogiltiga maskintyper, felaktiga regionnamn,
# avvecklade argument i google-providern.
plugin "google" {
  enabled = true
  version = "0.39.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
