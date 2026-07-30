package security

import "fmt"

// ErrInvalidControlCharacters mirrors
// MinimalIMAPClient.IMAPClientError.invalidControlCharacters.
type ErrInvalidControlCharacters struct{ Field string }

func (e *ErrInvalidControlCharacters) Error() string {
	return fmt.Sprintf("%s contains a CR, LF, NUL, or other control character", e.Field)
}

// ValidateNoControlCharacters rejects any C0 control character (0x00-0x1F)
// or DEL (0x7F) — CR/LF (the injection vector) plus NUL and everything
// else RFC 3501 disallows in a quoted-string/atom. Mirrors
// MinimalIMAPClient.validateNoControlCharacters(_:field:) exactly (CLAUDE-
// SECURITY F3) — called both at POST /v1/watches time (before anything is
// persisted) and again immediately before writing a value onto the IMAP
// wire, as a defense-in-depth backstop.
func ValidateNoControlCharacters(value string, field string) error {
	for _, r := range value {
		if r < 0x20 || r == 0x7F {
			return &ErrInvalidControlCharacters{Field: field}
		}
	}
	return nil
}
