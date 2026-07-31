package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/m-tkg/otegami-relay-go/internal/api"
)

// httpError mirrors RelayHTTPError — every non-2xx response from /v1/*
// uses api.ErrorResponse's shape instead of a framework-default error
// body, so the app's error handling has one JSON shape to decode
// regardless of which route failed.
type httpError struct {
	status int
	body   api.ErrorResponse
}

func (e *httpError) Error() string { return e.body.Message }

func unauthorized(message string) *httpError {
	if message == "" {
		message = "invalid or missing device credentials"
	}
	return &httpError{status: http.StatusUnauthorized, body: api.ErrorResponse{Error: "unauthorized", Message: message}}
}

func notFound(message string) *httpError {
	return &httpError{status: http.StatusNotFound, body: api.ErrorResponse{Error: "not_found", Message: message}}
}

func badRequest(message string) *httpError {
	return &httpError{status: http.StatusBadRequest, body: api.ErrorResponse{Error: "bad_request", Message: message}}
}

func writeError(w http.ResponseWriter, err *httpError) {
	w.Header().Set("content-type", "application/json; charset=utf-8")
	w.WriteHeader(err.status)
	_ = json.NewEncoder(w).Encode(err.body)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("content-type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func decodeJSON(r *http.Request, out any) *httpError {
	// 2 MiB cap, matching the Hummingbird BasicRequestContext default used
	// implicitly by the retired Swift relay.
	r.Body = http.MaxBytesReader(nil, r.Body, 2*1024*1024)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(out); err != nil {
		return badRequest("invalid JSON request body")
	}
	return nil
}
