package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestConfigHandler_UnlicensedBrand covers the ByWater fork's BRAND_* settings,
// which expose branding through the standard config keys without a license.
func TestConfigHandler_UnlicensedBrand(t *testing.T) {
	s := newTestServer(t, newMockDB(), 1, false)
	s.License = LicenseStatus{}
	s.BrandTitle = "Sharepass"
	s.BrandColor = "#87c0e9"
	s.BrandLogo = "https://cdn.example.com/logo.png"

	w := httptest.NewRecorder()
	s.configHandler(w, httptest.NewRequest(http.MethodGet, "/config", nil))

	var cfg map[string]interface{}
	if err := json.NewDecoder(w.Result().Body).Decode(&cfg); err != nil {
		t.Fatal(err)
	}
	if cfg["APP_NAME"] != s.BrandTitle {
		t.Errorf("APP_NAME: got %v, want %q", cfg["APP_NAME"], s.BrandTitle)
	}
	if cfg["LOGO_URL"] != s.BrandLogo {
		t.Errorf("LOGO_URL: got %v, want %q", cfg["LOGO_URL"], s.BrandLogo)
	}
	for _, key := range []string{"THEME_CUSTOM_LIGHT", "THEME_CUSTOM_DARK"} {
		vars, _ := cfg[key].(map[string]interface{})
		if vars["--color-primary"] != s.BrandColor {
			t.Errorf("%s: got %v, want --color-primary=%q", key, cfg[key], s.BrandColor)
		}
	}
}

func TestSecurityHeadersBrandLogoOrigin(t *testing.T) {
	y := newTestServer(t, newMockDB(), 1, false)
	y.BrandLogo = "https://cdn.example.com/logo.png"
	h := y.HTTPHandler()

	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/", nil))

	csp := rr.Header().Get("content-security-policy")
	want := "img-src 'self' data: https://cdn.example.com"
	if !strings.Contains(csp, want) {
		t.Errorf("expected CSP to contain %q, got %q", want, csp)
	}
}
