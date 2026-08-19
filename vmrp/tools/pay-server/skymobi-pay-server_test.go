package main

import (
	"bytes"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func mustParseTlv(t *testing.T, body []byte) map[uint32]tlvRecord {
	t.Helper()
	records, exact := parseTlvExact(body)
	if !exact {
		t.Fatal("body is not an exact TLV stream")
	}
	return tlvMap(records)
}

func makeRegRequest(version uint32) []tlvRecord {
	var plugins []byte
	plugins = append(plugins, tlvEncode(0x03e9, u32be(netpayAppID))...)
	plugins = append(plugins, tlvEncode(0x046f, u32be(version))...)
	return []tlvRecord{
		{Type: 0x0452, Len: 3, Value: []byte("REG")},
		{Type: 0x045b, Len: 4, Value: []byte{0x12, 0x34, 0x56, 0x78}},
		{Type: 0x046e, Len: uint32(len(plugins)), Value: plugins},
	}
}

func makePropRequest(txn []byte) []tlvRecord {
	return []tlvRecord{
		{Type: 0x0452, Len: 4, Value: []byte("PROP")},
		{Type: 0x045b, Len: uint32(len(txn)), Value: txn},
	}
}

func TestBuildDefaultBodyReturnsInteractiveUpdateForNetpay386(t *testing.T) {
	response := mustParseTlv(t, buildDefaultBody(makeRegRequest(installedNetpayVersion)))

	if got := response[100].Value; !bytes.Equal(got, u32be(203)) {
		t.Fatalf("status TLV = %x, want 203", got)
	}
	if got := response[200].Value; !bytes.Equal(got, []byte{12}) {
		t.Fatalf("action TLV = %x, want 12", got)
	}
	if got := response[111].Value; !bytes.Equal(got, u32be(1)) {
		t.Fatalf("update count TLV = %x, want 1", got)
	}

	item := mustParseTlv(t, response[112].Value)
	wants := map[uint32][]byte{
		113: u32be(netpayAppID),
		114: u32be(1),
		115: u32be(netpayAppID),
		116: u32be(serverNetpayVersion),
		117: u32be(0),
	}
	for typ, want := range wants {
		if got := item[typ].Value; !bytes.Equal(got, want) {
			t.Fatalf("update item TLV %d = %x, want %x", typ, got, want)
		}
	}
}

func TestBuildDefaultBodyDoesNotUpdateOtherNetpayVersions(t *testing.T) {
	response := mustParseTlv(t, buildDefaultBody(makeRegRequest(installedNetpayVersion-1)))

	if got := response[100].Value; !bytes.Equal(got, u32be(200)) {
		t.Fatalf("status TLV = %x, want 200", got)
	}
	if _, ok := response[111]; ok {
		t.Fatal("non-386 REG response unexpectedly contains an update count")
	}
}

func TestBuildDefaultBodyReturnsPropCompletion(t *testing.T) {
	txn := []byte{0xde, 0xad, 0xbe, 0xef}
	response := mustParseTlv(t, buildDefaultBody(makePropRequest(txn)))

	if got := response[101].Value; !bytes.Equal(got, txn) {
		t.Fatalf("transaction TLV = %x, want %x", got, txn)
	}
	if got := response[100].Value; !bytes.Equal(got, u32be(200)) {
		t.Fatalf("status TLV = %x, want 200", got)
	}
	if got := response[200].Value; !bytes.Equal(got, []byte{12}) {
		t.Fatalf("action TLV = %x, want 12", got)
	}
	if _, ok := response[111]; ok {
		t.Fatal("PROP response unexpectedly contains an update count")
	}
}

func TestBuildDefaultBodyRejectsPropWithoutTransaction(t *testing.T) {
	response := buildDefaultBody(makePropRequest(nil))
	if !bytes.Equal(response, nonEntitlingBody) {
		t.Fatalf("response = %x, want non-entitling body %x", response, nonEntitlingBody)
	}
}

func TestBuildDefaultBodyDoesNotEntitleUnknownStage(t *testing.T) {
	response := buildDefaultBody([]tlvRecord{
		{Type: 0x0452, Len: 7, Value: []byte("UNKNOWN")},
	})
	if !bytes.Equal(response, nonEntitlingBody) {
		t.Fatalf("response = %x, want non-entitling body %x", response, nonEntitlingBody)
	}
}

func TestBuildPayOneBodyEchoesMessageID(t *testing.T) {
	// Action 1 selects direct completion because the response has no SMS items.
	want, err := hex.DecodeString("0000006400000004000000c8000000650000000400001710000000c80000000101")
	if err != nil {
		t.Fatal(err)
	}
	if got := buildPayOneBody(5904); !bytes.Equal(got, want) {
		t.Fatalf("response = %x, want %x", got, want)
	}
}

func TestHandlerReturnsPayOneSuccess(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/payOne", strings.NewReader("appid=391046&msgid=5904"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	recorder := httptest.NewRecorder()

	handler(recorder, req)

	want, _ := hex.DecodeString("0000006400000004000000c8000000650000000400001710000000c80000000101")
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/octet-stream" {
		t.Fatalf("Content-Type = %q, want application/octet-stream", got)
	}
	if !bytes.Equal(recorder.Body.Bytes(), want) {
		t.Fatalf("body = %x, want %x", recorder.Body.Bytes(), want)
	}
}

func TestHandlerRejectsMalformedPayOneWithoutTlvFallback(t *testing.T) {
	for _, body := range []string{"appid=391046", "msgid=1&msgid=2", "msgid=4294967296"} {
		req := httptest.NewRequest(http.MethodPost, "/payOne", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		recorder := httptest.NewRecorder()

		handler(recorder, req)
		if recorder.Code != http.StatusBadRequest {
			t.Errorf("body %q: status = %d, want %d", body, recorder.Code, http.StatusBadRequest)
		}
	}
}

func TestHandlerPreservesPayOneAsTlvPropResponse(t *testing.T) {
	requestBody := append(tlvEncode(0x0452, []byte("PROP")), tlvEncode(0x045b, []byte{0xde, 0xad, 0xbe, 0xef})...)
	req := httptest.NewRequest(http.MethodPost, "/payOneAsTlv", bytes.NewReader(requestBody))
	recorder := httptest.NewRecorder()

	handler(recorder, req)

	want := buildDefaultBody(makePropRequest([]byte{0xde, 0xad, 0xbe, 0xef}))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/x-tar" {
		t.Fatalf("Content-Type = %q, want application/x-tar", got)
	}
	if !bytes.Equal(recorder.Body.Bytes(), want) {
		t.Fatalf("body = %x, want %x", recorder.Body.Bytes(), want)
	}
}

func TestHandlerRejectsUnknownPaymentPath(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/unknown", nil)
	recorder := httptest.NewRecorder()

	handler(recorder, req)

	if recorder.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusNotFound)
	}
}
