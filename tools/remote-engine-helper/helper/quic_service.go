package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/internal/registry"
	"fantastty/remote-engine-helper/remotegrid"
	"github.com/quic-go/quic-go"
)

const (
	remoteQUICALPN                 = "fantastty-remote-engine-v1"
	remoteQUICMaxDatagramFrameSize = 16383
	remoteQUICAttachReadLimit      = 4096
	remoteQUICRequestReadLimit     = 65536
)

type remoteWorkspacePayload struct {
	Reliable  []remotegrid.WorkspaceMessage
	Datagrams []remotegrid.PaneDelta
}

type remoteWorkspaceSource interface {
	CurrentPayload(workspaceID string) (remoteWorkspacePayload, error)
	RequestKeyframe(workspaceID string, paneID int) (remoteWorkspacePayload, error)
	RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error)
	SendKeys(workspaceID string, paneID int, data []byte) error
	ResizePane(workspaceID string, paneID int, columns int, rows int) (remoteWorkspacePayload, error)
	NewWindow(workspaceID string) (remoteWorkspacePayload, error)
	SelectWindow(workspaceID string, windowID int) (remoteWorkspacePayload, error)
	Subscribe(*engine.StreamPump) func()
	SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error)
}

type remoteWorkspacePayloadSource func(workspaceID string) (remoteWorkspacePayload, error)

func (f remoteWorkspacePayloadSource) CurrentPayload(workspaceID string) (remoteWorkspacePayload, error) {
	return f(workspaceID)
}

func (f remoteWorkspacePayloadSource) RequestKeyframe(workspaceID string, _ int) (remoteWorkspacePayload, error) {
	return f(workspaceID)
}

func (f remoteWorkspacePayloadSource) RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error) {
	payload, err := f(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	return remoteWorkspacePayload{Reliable: payload.Reliable}, nil
}

func (f remoteWorkspacePayloadSource) SendKeys(string, int, []byte) error {
	return nil
}

func (f remoteWorkspacePayloadSource) ResizePane(workspaceID string, _ int, _ int, _ int) (remoteWorkspacePayload, error) {
	return f(workspaceID)
}

func (f remoteWorkspacePayloadSource) NewWindow(workspaceID string) (remoteWorkspacePayload, error) {
	return f(workspaceID)
}

func (f remoteWorkspacePayloadSource) SelectWindow(workspaceID string, _ int) (remoteWorkspacePayload, error) {
	return f(workspaceID)
}

func (f remoteWorkspacePayloadSource) Subscribe(*engine.StreamPump) func() {
	return func() {}
}

func (f remoteWorkspacePayloadSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := f.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := f.Subscribe(pump)
	return payload, unsubscribe, nil
}

func queueInitialPayload(pump *engine.StreamPump, payload remoteWorkspacePayload) {
	if pump == nil {
		return
	}
	pump.PublishReliable(payload.Reliable)
	pump.PublishDatagrams(payload.Datagrams)
}

type authenticatedClientLifecycle interface {
	ClientAttached() error
	ClientDetached() error
}

type remoteQUICServerOptions struct {
	ListenAddr    string
	AdvertiseHost string
	RuntimeDir    string
	WorkspaceID   string
	Session       string
	Source        remoteWorkspaceSource
	Lifecycle     authenticatedClientLifecycle
	Log           io.Writer
}

type remoteQUICServer struct {
	listener *quic.Listener
	cancel   context.CancelFunc
	done     chan struct{}
	errc     chan error
	addr     string
	certSHA  string
}

type remoteAttachRequest struct {
	Session string `json:"session"`
	Key     string `json:"key"`
}

type remoteAttachError struct {
	Error string `json:"error"`
}

type remoteClientRequest struct {
	Type        string `json:"type"`
	WorkspaceID string `json:"workspaceID"`
	PaneID      int    `json:"paneID"`
	Reason      string `json:"reason"`
	Data        []byte `json:"data"`
	Columns     int    `json:"columns"`
	Rows        int    `json:"rows"`
	WindowID    int    `json:"windowID"`
}

type remoteQUICDatagramConn interface {
	SendDatagram([]byte) error
	CloseWithError(quic.ApplicationErrorCode, string) error
}

type remoteQUICDatagramWriter struct {
	conn               remoteQUICDatagramConn
	onDatagramTooLarge func(remotegrid.PaneDelta)
	mu                 sync.Mutex
	closed             bool
	pending            map[remoteQUICDatagramKey]remoteQUICPendingDatagram
	pendingOrder       []remoteQUICDatagramKey
	fallbacksInFlight  []remotegrid.PaneDelta
	pendingFallbacks   []remotegrid.PaneDelta
	senderRunning      bool
	sendInFlight       bool
}

type remoteQUICDatagramKey struct {
	workspaceID string
	paneID      int
	raw         bool
}

type remoteQUICPendingDatagram struct {
	payload    []byte
	delta      remotegrid.PaneDelta
	structured bool
}

func startRemoteQUICServer(ctx context.Context, opts remoteQUICServerOptions) (*remoteQUICServer, error) {
	if opts.ListenAddr == "" {
		opts.ListenAddr = "0.0.0.0:0"
	}
	if opts.RuntimeDir == "" {
		return nil, errors.New("remote QUIC server requires runtime dir")
	}
	if opts.WorkspaceID == "" || opts.Session == "" {
		return nil, errors.New("remote QUIC server requires workspace and session")
	}
	if opts.Source == nil {
		return nil, errors.New("remote QUIC server requires payload source")
	}
	if opts.Log == nil {
		opts.Log = io.Discard
	}

	tlsConfig, certSHA, err := newRemoteQUICTLSConfig()
	if err != nil {
		return nil, err
	}
	udpAddr, err := net.ResolveUDPAddr("udp", opts.ListenAddr)
	if err != nil {
		return nil, err
	}
	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return nil, err
	}
	listener, err := quic.Listen(udpConn, tlsConfig, newRemoteQUICConfig())
	if err != nil {
		_ = udpConn.Close()
		return nil, err
	}

	acceptCtx, cancel := context.WithCancel(ctx)
	server := &remoteQUICServer{
		listener: listener,
		cancel:   cancel,
		done:     make(chan struct{}),
		errc:     make(chan error, 1),
		addr:     advertisedAddr(listener.Addr(), opts.AdvertiseHost),
		certSHA:  certSHA,
	}
	go server.acceptLoop(acceptCtx, opts)
	return server, nil
}

func (s *remoteQUICServer) Addr() string {
	return s.addr
}

func (s *remoteQUICServer) Port() int {
	if addr, ok := s.listener.Addr().(*net.UDPAddr); ok {
		return addr.Port
	}
	_, port, err := net.SplitHostPort(s.listener.Addr().String())
	if err != nil {
		return 0
	}
	n, _ := net.LookupPort("udp", port)
	return n
}

func (s *remoteQUICServer) CertSHA256() string {
	return s.certSHA
}

func (s *remoteQUICServer) Close() error {
	s.cancel()
	err := s.listener.Close()
	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
		return errors.New("remote QUIC server did not stop")
	}
	return err
}

func (s *remoteQUICServer) acceptLoop(ctx context.Context, opts remoteQUICServerOptions) {
	defer close(s.done)
	var sequence int
	for {
		conn, err := s.listener.Accept(ctx)
		if err != nil {
			s.errc <- err
			return
		}
		sequence++
		go handleRemoteQUICConnection(ctx, conn, opts, sequence)
	}
}

func handleRemoteQUICConnection(ctx context.Context, conn *quic.Conn, opts remoteQUICServerOptions, sequence int) {
	state := conn.ConnectionState()
	fmt.Fprintf(
		opts.Log,
		"remote_quic_connection_accepted=true connection_sequence=%d remote=%s local=%s version=%s datagram_local=%t datagram_remote=%t\n",
		sequence,
		conn.RemoteAddr(),
		conn.LocalAddr(),
		state.Version,
		state.SupportsDatagrams.Local,
		state.SupportsDatagrams.Remote,
	)

	stream, err := conn.AcceptStream(ctx)
	if err != nil {
		_ = conn.CloseWithError(0, "")
		return
	}
	defer stream.Close()

	reader := bufio.NewReader(stream)
	request, err := readRemoteAttachRequest(reader)
	if err != nil {
		writeRemoteAttachError(stream, err)
		return
	}
	fmt.Fprintf(opts.Log, "remote_quic_attach_request=true connection_sequence=%d session=%s\n", sequence, request.Session)
	if err := consumeRemoteAttachKey(opts.RuntimeDir, opts.WorkspaceID, opts.Session, request); err != nil {
		writeRemoteAttachError(stream, err)
		return
	}
	fmt.Fprintf(opts.Log, "remote_quic_attach_authenticated=true connection_sequence=%d\n", sequence)

	if opts.Lifecycle != nil {
		if err := opts.Lifecycle.ClientAttached(); err != nil {
			writeRemoteAttachError(stream, err)
			return
		}
		defer func() {
			if err := opts.Lifecycle.ClientDetached(); err != nil {
				fmt.Fprintf(opts.Log, "remote_quic_client_detach_error=%q connection_sequence=%d\n", err, sequence)
			}
		}()
	}

	reliableWriter := remoteQUICReliableLogWriter{
		writer:             stream,
		log:                opts.Log,
		connectionSequence: sequence,
	}
	datagramWriter := &remoteQUICDatagramWriter{conn: conn}
	pump := engine.NewStreamPumpWithPausedDatagrams(reliableWriter, datagramWriter)
	datagramWriter.onDatagramTooLarge = pump.PublishReliableDeltaFallback
	payload, unsubscribe, err := opts.Source.SubscribeKeyframes(opts.WorkspaceID, pump)
	if err != nil {
		writeRemoteAttachError(stream, err)
		_ = pump.Close()
		return
	}
	connCtx, cancelConn := context.WithCancel(ctx)
	defer cancelConn()
	defer conn.CloseWithError(0, "")

	defer func() {
		unsubscribe()
		if err := pump.Close(); err != nil {
			fmt.Fprintf(opts.Log, "remote_quic_pump_close_error=%q connection_sequence=%d\n", err, sequence)
		}
	}()
	requestErr := make(chan error, 1)
	go func() {
		requestErr <- serveRemoteClientRequests(connCtx, reader, opts, pump)
	}()
	go serveRemoteClientRequestStreams(connCtx, conn, opts, pump)
	go serveRemoteClientRequestUniStreams(connCtx, conn, opts, pump)

	fmt.Fprintf(opts.Log, "remote_quic_initial_flush_started=true connection_sequence=%d reliable=%d datagrams=%d\n", sequence, len(payload.Reliable), len(payload.Datagrams))
	if err := pump.Flush(); err != nil {
		fmt.Fprintf(opts.Log, "remote_quic_stream_error=%q connection_sequence=%d\n", err, sequence)
		return
	}
	fmt.Fprintf(opts.Log, "remote_quic_initial_reliable_flush_completed=true connection_sequence=%d\n", sequence)
	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		fmt.Fprintf(opts.Log, "remote_quic_stream_error=%q connection_sequence=%d\n", err, sequence)
		return
	}
	fmt.Fprintf(opts.Log, "remote_quic_initial_flush_completed=true connection_sequence=%d\n", sequence)
	select {
	case err := <-requestErr:
		if err != nil {
			writeRemoteAttachError(stream, err)
		}
	case <-connCtx.Done():
	}
}

func serveRemoteClientRequestStreams(
	ctx context.Context,
	conn *quic.Conn,
	opts remoteQUICServerOptions,
	pump *engine.StreamPump,
) {
	for {
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			return
		}
		go func(stream *quic.Stream) {
			defer stream.Close()
			reader := bufio.NewReader(stream)
			if err := serveRemoteClientRequests(ctx, reader, opts, pump); err != nil {
				writeRemoteAttachError(stream, err)
			}
		}(stream)
	}
}

func serveRemoteClientRequestUniStreams(
	ctx context.Context,
	conn *quic.Conn,
	opts remoteQUICServerOptions,
	pump *engine.StreamPump,
) {
	for {
		stream, err := conn.AcceptUniStream(ctx)
		if err != nil {
			return
		}
		go func(stream *quic.ReceiveStream) {
			reader := bufio.NewReader(stream)
			_ = serveRemoteClientRequests(ctx, reader, opts, pump)
		}(stream)
	}
}

func readRemoteAttachRequest(reader *bufio.Reader) (remoteAttachRequest, error) {
	line, err := readRemoteJSONLine(reader, remoteQUICAttachReadLimit)
	if err != nil {
		return remoteAttachRequest{}, err
	}
	var request remoteAttachRequest
	if err := json.Unmarshal([]byte(line), &request); err != nil {
		return remoteAttachRequest{}, err
	}
	if request.Session == "" || request.Key == "" {
		return remoteAttachRequest{}, errors.New("attach request requires session and key")
	}
	return request, nil
}

func serveRemoteClientRequests(
	ctx context.Context,
	reader *bufio.Reader,
	opts remoteQUICServerOptions,
	pump *engine.StreamPump,
) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}
		line, err := readRemoteJSONLine(reader, remoteQUICRequestReadLimit)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		var request remoteClientRequest
		if err := json.Unmarshal([]byte(line), &request); err != nil {
			return err
		}
		fmt.Fprintf(opts.Log, "remote_quic_client_request_received=true type=%s workspace=%s pane=%d bytes=%d\n", request.Type, request.WorkspaceID, request.PaneID, len(request.Data))
		if err := handleRemoteClientRequest(request, opts, pump); err != nil {
			return err
		}
		fmt.Fprintf(opts.Log, "remote_quic_client_request_handled=true type=%s workspace=%s pane=%d\n", request.Type, request.WorkspaceID, request.PaneID)
		if err := pump.Flush(); err != nil {
			return err
		}
		fmt.Fprintf(opts.Log, "remote_quic_client_request_flushed=true type=%s workspace=%s pane=%d\n", request.Type, request.WorkspaceID, request.PaneID)
	}
}

func handleRemoteClientRequest(
	request remoteClientRequest,
	opts remoteQUICServerOptions,
	pump *engine.StreamPump,
) error {
	switch request.Type {
	case "requestKeyframe":
		if request.WorkspaceID != opts.WorkspaceID {
			return errors.New("keyframe request belongs to another workspace")
		}
		if request.PaneID < 0 {
			return errors.New("keyframe request requires paneID")
		}
		payload, err := opts.Source.RequestKeyframe(opts.WorkspaceID, request.PaneID)
		if err != nil {
			return err
		}
		if opts.Log != nil {
			fmt.Fprintf(opts.Log, "remote_quic_request_keyframe_payload=true workspace=%s pane=%d reliable=%d datagrams=%d\n", opts.WorkspaceID, request.PaneID, len(payload.Reliable), len(payload.Datagrams))
		}
		pump.PublishReliable(payload.Reliable)
		pump.PublishDatagrams(payload.Datagrams)
		return nil
	case "sendKeys":
		if request.WorkspaceID != opts.WorkspaceID {
			return errors.New("input request belongs to another workspace")
		}
		if request.PaneID < 0 {
			return errors.New("input request requires paneID")
		}
		if len(request.Data) == 0 {
			return nil
		}
		if err := opts.Source.SendKeys(opts.WorkspaceID, request.PaneID, request.Data); err != nil {
			return err
		}
		return nil
	case "resizePane":
		if request.WorkspaceID != opts.WorkspaceID {
			return errors.New("resize request belongs to another workspace")
		}
		if request.PaneID < 0 {
			return errors.New("resize request requires paneID")
		}
		if request.Columns <= 0 || request.Rows <= 0 {
			return errors.New("resize request requires positive columns and rows")
		}
		payload, err := opts.Source.ResizePane(opts.WorkspaceID, request.PaneID, request.Columns, request.Rows)
		if err != nil {
			return err
		}
		if pump != nil {
			pump.PublishReliable(payload.Reliable)
			pump.PublishDatagrams(payload.Datagrams)
		}
		return nil
	case "newWindow":
		if request.WorkspaceID != opts.WorkspaceID {
			return errors.New("new-window request belongs to another workspace")
		}
		payload, err := opts.Source.NewWindow(opts.WorkspaceID)
		if err != nil {
			return err
		}
		if pump != nil {
			pump.PublishReliable(payload.Reliable)
			pump.PublishDatagrams(payload.Datagrams)
		}
		return nil
	case "selectWindow":
		if request.WorkspaceID != opts.WorkspaceID {
			return errors.New("select-window request belongs to another workspace")
		}
		if request.WindowID < 0 {
			return errors.New("select-window request requires windowID")
		}
		payload, err := opts.Source.SelectWindow(opts.WorkspaceID, request.WindowID)
		if err != nil {
			return err
		}
		if pump != nil {
			pump.PublishReliable(payload.Reliable)
			pump.PublishDatagrams(payload.Datagrams)
		}
		return nil
	default:
		return fmt.Errorf("unsupported remote client request type %q", request.Type)
	}
}

func readRemoteJSONLine(reader *bufio.Reader, limit int) (string, error) {
	var line strings.Builder
	for {
		chunk, isPrefix, err := reader.ReadLine()
		if err != nil {
			return "", err
		}
		if line.Len()+len(chunk) > limit {
			return "", errors.New("remote request too large")
		}
		line.Write(chunk)
		if !isPrefix {
			return line.String(), nil
		}
	}
}

func consumeRemoteAttachKey(runtimeDir, workspaceID, session string, request remoteAttachRequest) error {
	store, err := registry.NewStore(runtimeDir, registry.Options{UID: os.Geteuid()})
	if err != nil {
		return err
	}
	manager := registry.NewManager(store)
	record, err := manager.ConsumeKey(request.Session, request.Key)
	if err != nil {
		return err
	}
	if record.Session != session || record.Workspace != workspaceID {
		return errors.New("attach key belongs to another remote session")
	}
	return nil
}

func writeRemoteAttachError(writer io.Writer, err error) {
	response := remoteAttachError{Error: err.Error()}
	line, marshalErr := json.Marshal(response)
	if marshalErr != nil {
		return
	}
	line = append(line, '\n')
	_, _ = writer.Write(line)
}

type remoteQUICReliableLogWriter struct {
	writer             io.Writer
	log                io.Writer
	connectionSequence int
}

func (w remoteQUICReliableLogWriter) Write(payload []byte) (int, error) {
	writer := w.writer
	if writer == nil {
		writer = io.Discard
	}
	n, err := writer.Write(payload)
	if w.log != nil {
		kind := remoteQUICReliablePayloadKind(payload)
		if err != nil {
			fmt.Fprintf(w.log, "remote_quic_reliable_write_failed=true connection_sequence=%d kind=%s bytes=%d reason=%s\n", w.connectionSequence, kind, len(payload), controlErrorDetail(err))
		} else {
			fmt.Fprintf(w.log, "remote_quic_reliable_write_completed=true connection_sequence=%d kind=%s bytes=%d\n", w.connectionSequence, kind, len(payload))
		}
	}
	return n, err
}

func remoteQUICReliablePayloadKind(payload []byte) string {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(bytesTrimSpace(payload), &envelope); err != nil {
		return "unknown"
	}
	for _, key := range []string{"workspaceSnapshot", "paneKeyframe", "paneDelta", "unsupportedPaneState", "error"} {
		if _, ok := envelope[key]; ok {
			return key
		}
	}
	return "unknown"
}

func (w *remoteQUICDatagramWriter) WriteDatagram(payload []byte) error {
	return w.enqueueDatagram(remotegrid.PaneDelta{}, payload, false)
}

func (w *remoteQUICDatagramWriter) WriteLatestDatagram(delta remotegrid.PaneDelta, payload []byte) error {
	return w.enqueueDatagram(delta, payload, true)
}

func (w *remoteQUICDatagramWriter) enqueueDatagram(delta remotegrid.PaneDelta, payload []byte, structured bool) error {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return nil
	}
	if w.pending == nil {
		w.pending = make(map[remoteQUICDatagramKey]remoteQUICPendingDatagram)
	}
	key := remoteQUICDatagramKey{raw: true}
	if structured {
		key = remoteQUICDatagramKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}
	}
	if structured && w.deltaDependsOnFallbackInFlightLocked(delta) {
		w.pendingFallbacks = append(w.pendingFallbacks, delta)
		w.mu.Unlock()
		return nil
	}
	if existing, ok := w.pending[key]; ok && structured && existing.structured {
		merged, changed, err := remoteQUICMergePendingDatagram(existing.delta, delta)
		if err != nil {
			w.mu.Unlock()
			return err
		}
		if !changed {
			w.mu.Unlock()
			return nil
		}
		delta = merged
		payload, err = remotegrid.MarshalCompactPaneDelta(merged)
		if err != nil {
			w.mu.Unlock()
			return err
		}
	} else if _, ok := w.pending[key]; !ok {
		w.pendingOrder = append(w.pendingOrder, key)
	}
	w.pending[key] = remoteQUICPendingDatagram{
		payload:    append([]byte(nil), payload...),
		delta:      delta,
		structured: structured,
	}
	if !w.senderRunning {
		w.senderRunning = true
		go w.sendLatestDatagrams()
	}
	w.mu.Unlock()
	return nil
}

func remoteQUICMergePendingDatagram(current remotegrid.PaneDelta, next remotegrid.PaneDelta) (remotegrid.PaneDelta, bool, error) {
	outbox := remotegrid.NewLatestDeltaOutbox()
	outbox.Publish(current)
	if !outbox.Publish(next) {
		return current, false, nil
	}
	deltas := outbox.Snapshot()
	if len(deltas) != 1 {
		return remotegrid.PaneDelta{}, false, fmt.Errorf("remote quic pending datagram merge produced %d deltas, want 1", len(deltas))
	}
	return deltas[0], true, nil
}

func (w *remoteQUICDatagramWriter) sendLatestDatagrams() {
	for {
		w.mu.Lock()
		if w.closed {
			w.senderRunning = false
			w.mu.Unlock()
			return
		}
		item, ok := w.nextPendingDatagramLocked()
		if !ok {
			w.senderRunning = false
			w.mu.Unlock()
			return
		}
		w.sendInFlight = true
		tooLargeCallback := w.onDatagramTooLarge
		w.mu.Unlock()

		err := w.conn.SendDatagram(item.payload)
		var tooLarge *quic.DatagramTooLargeError
		shouldFallback := errors.As(err, &tooLarge) && item.structured && tooLargeCallback != nil
		var fallbackDeltas []remotegrid.PaneDelta

		w.mu.Lock()
		w.sendInFlight = false
		closed := w.closed
		if err != nil && !shouldFallback || closed {
			w.senderRunning = false
			w.pending = nil
			w.pendingOrder = nil
			w.mu.Unlock()
			return
		}
		if shouldFallback {
			fallbackDeltas = append(fallbackDeltas, item.delta)
			fallbackDeltas = append(fallbackDeltas, w.removePendingDatagramsDependentOnLocked(item.delta)...)
			w.fallbacksInFlight = append(w.fallbacksInFlight, fallbackDeltas...)
		}
		w.mu.Unlock()
		if shouldFallback {
			w.publishFallbackDeltas(tooLargeCallback, fallbackDeltas)
		}
	}
}

func (w *remoteQUICDatagramWriter) nextPendingDatagramLocked() (remoteQUICPendingDatagram, bool) {
	for len(w.pendingOrder) > 0 {
		key := w.pendingOrder[0]
		w.pendingOrder = w.pendingOrder[1:]
		item, ok := w.pending[key]
		if !ok {
			continue
		}
		delete(w.pending, key)
		return item, true
	}
	return remoteQUICPendingDatagram{}, false
}

func (w *remoteQUICDatagramWriter) deltaDependsOnFallbackInFlightLocked(delta remotegrid.PaneDelta) bool {
	if remoteQUICDeltaDependsOnAnyFallback(delta, w.fallbacksInFlight) {
		return true
	}
	return remoteQUICDeltaDependsOnAnyFallback(delta, w.pendingFallbacks)
}

func (w *remoteQUICDatagramWriter) publishFallbackDeltas(callback func(remotegrid.PaneDelta), fallbackDeltas []remotegrid.PaneDelta) {
	for {
		for _, fallback := range fallbackDeltas {
			callback(fallback)
		}

		w.mu.Lock()
		if len(w.pendingFallbacks) == 0 {
			w.fallbacksInFlight = nil
			w.mu.Unlock()
			return
		}
		fallbackDeltas = append([]remotegrid.PaneDelta(nil), w.pendingFallbacks...)
		w.pendingFallbacks = nil
		w.fallbacksInFlight = append(w.fallbacksInFlight, fallbackDeltas...)
		w.mu.Unlock()
	}
}

func (w *remoteQUICDatagramWriter) removePendingDatagramsDependentOnLocked(fallback remotegrid.PaneDelta) []remotegrid.PaneDelta {
	if len(w.pendingOrder) == 0 {
		return nil
	}
	fallbacks := make([]remotegrid.PaneDelta, 0)
	for _, key := range w.pendingOrder {
		item, ok := w.pending[key]
		if !ok || !item.structured {
			continue
		}
		if !remoteQUICDeltaDependsOnFallback(item.delta, fallback) {
			continue
		}
		delete(w.pending, key)
		fallbacks = append(fallbacks, item.delta)
	}
	return fallbacks
}

func remoteQUICDeltaDependsOnAnyFallback(delta remotegrid.PaneDelta, fallbacks []remotegrid.PaneDelta) bool {
	for _, fallback := range fallbacks {
		if remoteQUICDeltaDependsOnFallback(delta, fallback) {
			return true
		}
	}
	return false
}

func remoteQUICDeltaDependsOnFallback(delta remotegrid.PaneDelta, fallback remotegrid.PaneDelta) bool {
	if delta.WorkspaceID != fallback.WorkspaceID ||
		delta.PaneID != fallback.PaneID ||
		delta.PaneGeneration != fallback.PaneGeneration ||
		delta.BaseKeyframeID != fallback.BaseKeyframeID {
		return false
	}
	fallbackRows := make(map[int]uint64, len(fallback.RowUpdates))
	for _, update := range fallback.RowUpdates {
		fallbackRows[update.RowIndex] = update.RowVersion
	}
	for _, update := range delta.RowUpdates {
		baseRowVersion, ok := update.Update.SpanBaseRowVersion()
		if !ok {
			continue
		}
		if fallbackRows[update.RowIndex] >= baseRowVersion {
			return true
		}
	}
	return false
}

func (w *remoteQUICDatagramWriter) Close() error {
	if w.conn == nil {
		return nil
	}
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return nil
	}
	w.closed = true
	w.pending = nil
	w.pendingOrder = nil
	w.fallbacksInFlight = nil
	w.pendingFallbacks = nil
	closeConnection := w.senderRunning || w.sendInFlight
	w.mu.Unlock()
	if !closeConnection {
		return nil
	}
	return w.conn.CloseWithError(0, "stream pump closed")
}

func requestRemoteQUICPayload(ctx context.Context, addr, certSHA, session, key string) ([]byte, error) {
	conn, err := quic.DialAddr(ctx, addr, remoteQUICClientTLSConfig(certSHA), &quic.Config{EnableDatagrams: true})
	if err != nil {
		return nil, err
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return nil, err
	}
	if err := stream.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return nil, err
	}
	if err := stream.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return nil, err
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", session, key); err != nil {
		return nil, err
	}

	output, err := readRemoteQUICInitialPayload(stream)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(string(output), `{"error":`) {
		var response remoteAttachError
		if err := json.Unmarshal(bytesTrimSpace(output), &response); err != nil {
			return nil, err
		}
		return nil, errors.New(response.Error)
	}
	if len(output) == 0 {
		return nil, errors.New("remote QUIC response was empty")
	}
	return output, nil
}

type remoteQUICInputProbeResult struct {
	WorkspaceID string
	PaneID      int
}

func requestRemoteQUICInputProbe(ctx context.Context, addr, certSHA, session, key, marker string) (remoteQUICInputProbeResult, error) {
	if !validRemoteInputProbeMarker(marker) {
		return remoteQUICInputProbeResult{}, errors.New("input probe marker contains unsupported characters")
	}

	conn, err := quic.DialAddr(ctx, addr, remoteQUICClientTLSConfig(certSHA), &quic.Config{EnableDatagrams: true})
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if err := stream.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if err := stream.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", session, key); err != nil {
		return remoteQUICInputProbeResult{}, err
	}

	reader := bufio.NewReader(stream)
	firstLine, err := reader.ReadBytes('\n')
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if strings.HasPrefix(string(bytesTrimSpace(firstLine)), `{"error":`) {
		var response remoteAttachError
		if err := json.Unmarshal(bytesTrimSpace(firstLine), &response); err != nil {
			return remoteQUICInputProbeResult{}, err
		}
		return remoteQUICInputProbeResult{}, errors.New(response.Error)
	}
	target, err := remoteInputProbeTargetFromSnapshot(firstLine)
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if _, err := reader.ReadBytes('\n'); err != nil {
		return remoteQUICInputProbeResult{}, err
	}

	command := fmt.Sprintf("printf '%%s\\n' %s\n", marker)
	request := remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: target.WorkspaceID,
		PaneID:      target.PaneID,
		Data:        []byte(command),
	}
	if err := writeRemoteClientRequest(stream, request); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if err := waitForRemoteInputMarker(ctx, conn, stream, reader, target, marker); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	return target, nil
}

func requestRemoteQUICReconnectProbe(ctx context.Context, addr, certSHA, session, firstKey, secondKey, marker string) (remoteQUICInputProbeResult, error) {
	if !validRemoteInputProbeMarker(marker) {
		return remoteQUICInputProbeResult{}, errors.New("reconnect probe marker contains unsupported characters")
	}

	target, err := driveRemoteQUICReconnectProbeInput(ctx, addr, certSHA, session, firstKey, marker)
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if err := verifyRemoteQUICReconnectBarrier(ctx, addr, certSHA, session, secondKey, marker); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	return target, nil
}

func driveRemoteQUICReconnectProbeInput(ctx context.Context, addr, certSHA, session, key, marker string) (remoteQUICInputProbeResult, error) {
	conn, stream, reader, err := openRemoteQUICProbeStream(ctx, addr, certSHA, session, key)
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	defer conn.CloseWithError(0, "")

	firstLine, err := reader.ReadBytes('\n')
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if err := remoteQUICAttachErrorFromLine(firstLine); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	target, err := remoteInputProbeTargetFromSnapshot(firstLine)
	if err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if secondLine, err := reader.ReadBytes('\n'); err != nil {
		return remoteQUICInputProbeResult{}, err
	} else if err := remoteQUICAttachErrorFromLine(secondLine); err != nil {
		return remoteQUICInputProbeResult{}, err
	}

	command := fmt.Sprintf("printf '%%s\\n' %s\n", marker)
	request := remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: target.WorkspaceID,
		PaneID:      target.PaneID,
		Data:        []byte(command),
	}
	if err := writeRemoteClientRequest(stream, request); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if err := waitForRemoteDatagramMarker(ctx, conn, marker); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	return target, nil
}

func verifyRemoteQUICReconnectBarrier(ctx context.Context, addr, certSHA, session, key, marker string) error {
	conn, _, reader, err := openRemoteQUICProbeStream(ctx, addr, certSHA, session, key)
	if err != nil {
		return err
	}
	defer conn.CloseWithError(0, "")

	output, err := readRemoteQUICReliablePrefixBeforeDatagram(ctx, conn, reader, 2)
	if err != nil {
		return err
	}
	if !remoteJSONLinesContainMarker(output, marker) {
		return fmt.Errorf("reconnect reliable keyframe did not contain marker %q", marker)
	}

	datagramCtx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
	defer cancel()
	datagram, err := conn.ReceiveDatagram(datagramCtx)
	if err == nil {
		return fmt.Errorf("reconnect replayed retained datagram after reliable keyframe barrier: %s", datagram)
	}
	if !remoteProbeTimeout(err) {
		return err
	}
	return nil
}

func openRemoteQUICProbeStream(ctx context.Context, addr, certSHA, session, key string) (*quic.Conn, *quic.Stream, *bufio.Reader, error) {
	conn, err := quic.DialAddr(ctx, addr, remoteQUICClientTLSConfig(certSHA), &quic.Config{EnableDatagrams: true})
	if err != nil {
		return nil, nil, nil, err
	}
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		_ = conn.CloseWithError(0, "")
		return nil, nil, nil, err
	}
	if err := stream.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		_ = conn.CloseWithError(0, "")
		return nil, nil, nil, err
	}
	if err := stream.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		_ = conn.CloseWithError(0, "")
		return nil, nil, nil, err
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", session, key); err != nil {
		_ = conn.CloseWithError(0, "")
		return nil, nil, nil, err
	}
	return conn, stream, bufio.NewReader(stream), nil
}

func waitForRemoteDatagramMarker(ctx context.Context, conn *quic.Conn, marker string) error {
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			return err
		}
		datagramCtx, cancel := context.WithTimeout(ctx, 150*time.Millisecond)
		datagram, err := conn.ReceiveDatagram(datagramCtx)
		cancel()
		if err == nil {
			if remoteJSONTextContainsMarker(datagram, marker) {
				return nil
			}
			continue
		}
		if !remoteProbeTimeout(err) {
			return err
		}
	}
	return fmt.Errorf("reconnect probe marker %q did not arrive as a datagram before reconnect", marker)
}

func readRemoteQUICReliablePrefixBeforeDatagram(ctx context.Context, conn *quic.Conn, reader *bufio.Reader, count int) ([]byte, error) {
	var output []byte
	for range count {
		line, err := readRemoteQUICReliableLineBeforeDatagram(ctx, conn, reader)
		if err != nil {
			return nil, err
		}
		if err := remoteQUICAttachErrorFromLine(line); err != nil {
			return nil, err
		}
		output = append(output, line...)
	}
	return output, nil
}

type remoteQUICPayloadRaceResult struct {
	payload []byte
	err     error
}

func readRemoteQUICReliableLineBeforeDatagram(ctx context.Context, conn *quic.Conn, reader *bufio.Reader) ([]byte, error) {
	datagramCtx, cancelDatagram := context.WithCancel(ctx)
	defer cancelDatagram()

	reliable := make(chan remoteQUICPayloadRaceResult, 1)
	go func() {
		line, err := reader.ReadBytes('\n')
		reliable <- remoteQUICPayloadRaceResult{payload: line, err: err}
	}()

	datagram := make(chan remoteQUICPayloadRaceResult, 1)
	go func() {
		payload, err := conn.ReceiveDatagram(datagramCtx)
		datagram <- remoteQUICPayloadRaceResult{payload: payload, err: err}
	}()

	select {
	case result := <-reliable:
		if result.err != nil {
			return nil, result.err
		}
		return result.payload, nil
	case result := <-datagram:
		if result.err != nil {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			return nil, result.err
		}
		return nil, fmt.Errorf("received datagram before reconnect reliable keyframe: %s", result.payload)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func remoteQUICAttachErrorFromLine(line []byte) error {
	if !strings.HasPrefix(string(bytesTrimSpace(line)), `{"error":`) {
		return nil
	}
	var response remoteAttachError
	if err := json.Unmarshal(bytesTrimSpace(line), &response); err != nil {
		return err
	}
	return errors.New(response.Error)
}

func writeRemoteClientRequest(writer io.Writer, request remoteClientRequest) error {
	line, err := json.Marshal(request)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	_, err = writer.Write(line)
	return err
}

func waitForRemoteInputMarker(
	ctx context.Context,
	conn *quic.Conn,
	stream *quic.Stream,
	reader *bufio.Reader,
	target remoteQUICInputProbeResult,
	marker string,
) error {
	deadline := time.Now().Add(5 * time.Second)
	keyframeRequested := false
	for time.Now().Before(deadline) {
		datagramCtx, cancel := context.WithTimeout(ctx, 150*time.Millisecond)
		datagram, err := conn.ReceiveDatagram(datagramCtx)
		cancel()
		if err == nil && remoteJSONTextContainsMarker(datagram, marker) {
			return nil
		}
		if err != nil && !remoteProbeTimeout(err) {
			return err
		}

		if !keyframeRequested && time.Until(deadline) < 4*time.Second {
			keyframeRequested = true
			if err := writeRemoteClientRequest(stream, remoteClientRequest{
				Type:        "requestKeyframe",
				WorkspaceID: target.WorkspaceID,
				PaneID:      target.PaneID,
				Reason:      "inputProbe",
			}); err != nil {
				return err
			}
		}

		if err := stream.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
			return err
		}
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 && remoteJSONTextContainsMarker(line, marker) {
			return nil
		}
		if err != nil && !remoteProbeTimeout(err) {
			return err
		}
	}
	return fmt.Errorf("input marker %q did not appear in remote grid output", marker)
}

func remoteProbeTimeout(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) {
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func validRemoteInputProbeMarker(marker string) bool {
	if marker == "" || len(marker) > 80 {
		return false
	}
	for _, r := range marker {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.' {
			continue
		}
		return false
	}
	return true
}

func remoteInputProbeTargetFromSnapshot(line []byte) (remoteQUICInputProbeResult, error) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(bytesTrimSpace(line), &envelope); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	rawSnapshot, ok := envelope["workspaceSnapshot"]
	if !ok {
		return remoteQUICInputProbeResult{}, errors.New("input probe expected workspace snapshot")
	}
	var snapshot struct {
		Value struct {
			WorkspaceID string `json:"workspaceID"`
			Panes       []struct {
				PaneID   *int `json:"paneID"`
				IsActive bool `json:"isActive"`
			} `json:"panes"`
		} `json:"_0"`
	}
	if err := json.Unmarshal(rawSnapshot, &snapshot); err != nil {
		return remoteQUICInputProbeResult{}, err
	}
	if snapshot.Value.WorkspaceID == "" {
		return remoteQUICInputProbeResult{}, errors.New("input probe snapshot missing workspace")
	}
	for _, pane := range snapshot.Value.Panes {
		if pane.IsActive && pane.PaneID != nil && *pane.PaneID >= 0 {
			return remoteQUICInputProbeResult{WorkspaceID: snapshot.Value.WorkspaceID, PaneID: *pane.PaneID}, nil
		}
	}
	for _, pane := range snapshot.Value.Panes {
		if pane.PaneID != nil && *pane.PaneID >= 0 {
			return remoteQUICInputProbeResult{WorkspaceID: snapshot.Value.WorkspaceID, PaneID: *pane.PaneID}, nil
		}
	}
	return remoteQUICInputProbeResult{}, errors.New("input probe snapshot has no pane")
}

func remoteJSONTextContainsMarker(data []byte, marker string) bool {
	var value any
	if err := json.Unmarshal(bytesTrimSpace(data), &value); err != nil {
		return false
	}
	var text strings.Builder
	collectRemoteJSONText(value, &text)
	return strings.Contains(text.String(), marker)
}

func remoteJSONLinesContainMarker(data []byte, marker string) bool {
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		if remoteJSONTextContainsMarker([]byte(line), marker) {
			return true
		}
	}
	return false
}

func collectRemoteJSONText(value any, text *strings.Builder) {
	switch typed := value.(type) {
	case []any:
		for _, item := range typed {
			collectRemoteJSONText(item, text)
		}
	case map[string]any:
		if cellText, ok := typed["text"].(string); ok {
			text.WriteString(cellText)
		}
		if fullRowText, ok := typed["fullRowText"].(map[string]any); ok {
			if rowText, ok := fullRowText["_0"].(string); ok {
				text.WriteString(rowText)
			}
		}
		for key, item := range typed {
			if key == "text" {
				continue
			}
			collectRemoteJSONText(item, text)
		}
	}
}

func readRemoteQUICInitialPayload(reader io.Reader) ([]byte, error) {
	buf := bufio.NewReader(reader)
	var output []byte
	for range 2 {
		line, err := buf.ReadBytes('\n')
		if err != nil {
			return nil, err
		}
		output = append(output, line...)
		if strings.HasPrefix(string(bytesTrimSpace(line)), `{"error":`) {
			return output, nil
		}
	}
	return output, nil
}

func remoteQUICClientTLSConfig(certSHA string) *tls.Config {
	return &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{remoteQUICALPN},
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("missing peer certificate")
			}
			cert, err := x509.ParseCertificate(rawCerts[0])
			if err != nil {
				return err
			}
			spkiSHA := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
			if got := hex.EncodeToString(spkiSHA[:]); got != certSHA {
				return fmt.Errorf("SPKI SHA256 = %s, want %s", got, certSHA)
			}
			return nil
		},
	}
}

func newRemoteQUICConfig() *quic.Config {
	return &quic.Config{
		EnableDatagrams: true,
		MaxIdleTimeout:  2 * time.Minute,
		KeepAlivePeriod: 10 * time.Second,
	}
}

func newRemoteQUICTLSConfig() (*tls.Config, string, error) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, "", err
	}
	spki, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		return nil, "", err
	}
	spkiSHA := sha256.Sum256(spki)

	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return nil, "", err
	}
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName: "fantastty-remote-engine",
		},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"fantastty-remote-engine"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, "", err
	}
	return &tls.Config{
		Certificates: []tls.Certificate{{
			Certificate: [][]byte{certDER},
			PrivateKey:  privateKey,
		}},
		NextProtos: []string{remoteQUICALPN},
		MinVersion: tls.VersionTLS13,
	}, hex.EncodeToString(spkiSHA[:]), nil
}

func advertisedAddr(addr net.Addr, hostOverride string) string {
	host, port, err := net.SplitHostPort(addr.String())
	if err != nil {
		return addr.String()
	}
	if hostOverride != "" {
		host = hostOverride
	}
	if host == "" || host == "::" || host == "0.0.0.0" || strings.HasPrefix(host, "[::]") {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, port)
}

func bytesTrimSpace(data []byte) []byte {
	return []byte(strings.TrimSpace(string(data)))
}
