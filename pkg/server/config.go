package server

import (
	"encoding/json"
	"net/http"
)

// DefaultThemeLight and DefaultThemeDark are the built-in DaisyUI themes used
// when no valid license overrides them. cmd/yopass-server uses them as the
// defaults for the --theme-light and --theme-dark flags.
const (
	DefaultThemeLight = "emerald"
	DefaultThemeDark  = "dim"
)

func (y *Server) configHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Headers", "content-type")
	w.Header().Set("Content-Type", "application/json")

	defaultOneTimeSecrets := true
	if y.DefaultOneTimeSecrets != nil {
		defaultOneTimeSecrets = *y.DefaultOneTimeSecrets
	}
	minExpiration, maxExpiration := y.expirationBounds()
	config := map[string]interface{}{
		"ALLOW_CUSTOM_EXPIRATION": y.AllowCustomExpiration,
		"MIN_EXPIRATION":          minExpiration,
		"MAX_EXPIRATION":          maxExpiration,
		"DISABLE_UPLOAD":          y.DisableUpload,
		"READ_ONLY":               y.ReadOnly,
		"PREFETCH_SECRET":         y.PrefetchSecret,
		"DISABLE_FEATURES":        y.DisableFeatures,
		"DISABLE_ONE_CLICK_LINK":  y.DisableOneClickLink,
		"NO_LANGUAGE_SWITCHER":    y.NoLanguageSwitcher,
		"NO_THEME_SWITCHER":       y.NoThemeSwitcher,
		"FORCE_ONETIME_SECRETS":   y.ForceOneTimeSecrets,
		"DEFAULT_ONETIME_SECRETS": defaultOneTimeSecrets,
		"DEFAULT_READ_RECEIPT":    y.DefaultReadReceipt,
		"DEFAULT_EXPIRY":          expirationInSeconds(y.DefaultExpiry),
		"ARGON2":                  y.Argon2,
	}
	if y.ForceExpiration != "" {
		config["FORCE_EXPIRATION"] = expirationInSeconds(y.ForceExpiration)
	}
	if maxFileSize := y.effectiveMaxFileSize(); maxFileSize > 0 {
		config["MAX_FILE_SIZE"] = FormatSize(maxFileSize)
	}

	// Add optional string URLs only if they are provided
	if y.PrivacyNoticeURL != "" {
		config["PRIVACY_NOTICE_URL"] = y.PrivacyNoticeURL
	}
	if y.ImprintURL != "" {
		config["IMPRINT_URL"] = y.ImprintURL
	}
	if y.PublicURL != "" {
		config["PUBLIC_URL"] = y.PublicURL
	}
	if y.License.CurrentlyValid() && y.LogoURL != "" {
		config["LOGO_URL"] = y.LogoURL
	}

	config["OIDC_ENABLED"] = y.oidcEnabled()
	config["REQUIRE_AUTH"] = y.oidcEnabled() && y.RequireAuth
	config["SECRET_REQUESTS"] = y.secretRequestsEnabled()
	config["SECRET_REQUESTS_DRAINING"] = y.secretRequestRoutesEnabled() && !y.secretRequestsEnabled()
	// File responses to secret requests have their own, stricter size limit
	// (they are stored in the database backend, not the file store).
	if y.secretRequestRoutesEnabled() && !y.DisableUpload {
		config["MAX_REQUEST_FILE_SIZE"] = FormatSize(y.effectiveRequestFileSize())
	}
	// The toggle is only useful where secrets can be created, so read-only
	// instances report false even with a valid license.
	config["READ_RECEIPTS"] = y.readReceiptsEnabled() && !y.ReadOnly

	if y.License.CurrentlyValid() {
		config["THEME_LIGHT"] = y.ThemeLight
		config["THEME_DARK"] = y.ThemeDark

		if y.ThemeCustomLight != "" {
			var vars map[string]string
			if err := json.Unmarshal([]byte(y.ThemeCustomLight), &vars); err == nil {
				config["THEME_CUSTOM_LIGHT"] = vars
			}
		}
		if y.ThemeCustomDark != "" {
			var vars map[string]string
			if err := json.Unmarshal([]byte(y.ThemeCustomDark), &vars); err == nil {
				config["THEME_CUSTOM_DARK"] = vars
			}
		}

		if y.AppName != "" {
			config["APP_NAME"] = y.AppName
		}
		if y.HideAppName {
			config["HIDE_APP_NAME"] = true
		}
	} else {
		config["THEME_LIGHT"] = DefaultThemeLight
		config["THEME_DARK"] = DefaultThemeDark
	}

	// Branding without a license key (ByWater fork): expose the BRAND_*
	// settings through the config keys the website already renders, so they
	// work with or without a license and take precedence when both are set.
	if y.BrandTitle != "" {
		config["APP_NAME"] = y.BrandTitle
	}
	if y.BrandLogo != "" {
		config["LOGO_URL"] = y.BrandLogo
	}
	for _, theme := range []struct{ key, vars string }{
		{"THEME_CUSTOM_LIGHT", y.BrandThemeLight},
		{"THEME_CUSTOM_DARK", y.BrandThemeDark},
	} {
		vars, _ := config[theme.key].(map[string]string)
		if vars == nil {
			vars = map[string]string{}
		}
		// BRAND_COLOR is the simple form; a per-theme JSON can refine it,
		// e.g. a lighter primary for the dark theme
		if y.BrandColor != "" {
			vars["--color-primary"] = y.BrandColor
		}
		if theme.vars != "" {
			var brandVars map[string]string
			if err := json.Unmarshal([]byte(theme.vars), &brandVars); err == nil {
				for k, v := range brandVars {
					vars[k] = v
				}
			}
		}
		if len(vars) > 0 {
			config[theme.key] = vars
		}
	}

	y.writeJSON(w, http.StatusOK, config)
}
