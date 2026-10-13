// Package gost реализует клиент протокола GOST Relay (TCP CONNECT).
// Формат запроса: VER(1)=1 | CMD(1)=1 | FEALEN(2) | features, feature = TYPE(1) LEN(2) DATA.
package gost

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/dialer"
	"github.com/sagernet/sing-box/common/tls"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/transport/v2ray"
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const TypeGost = "gost"

func RegisterOutbound(registry *outbound.Registry) {
	outbound.Register[option.GostOutboundOptions](registry, TypeGost, NewOutbound)
}

type Outbound struct {
	outbound.Adapter
	logger     logger.ContextLogger
	dialer     N.Dialer
	serverAddr M.Socksaddr
	username   string
	password   string
	tlsConfig  tls.Config
	tlsDialer  tls.Dialer
	transport  adapter.V2RayClientTransport
}

func NewOutbound(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options option.GostOutboundOptions) (adapter.Outbound, error) {
	outboundDialer, err := dialer.New(ctx, options.DialerOptions, options.ServerIsDomain())
	if err != nil {
		return nil, err
	}
	h := &Outbound{
		Adapter:    outbound.NewAdapterWithDialerOptions(TypeGost, tag, []string{N.NetworkTCP}, options.DialerOptions),
		logger:     logger,
		dialer:     outboundDialer,
		serverAddr: options.ServerOptions.Build(),
		username:   options.Username,
		password:   options.Password,
	}
	if options.TLS != nil {
		h.tlsConfig, err = tls.NewClientWithOptions(tls.ClientOptions{
			Context:        ctx,
			Logger:         logger,
			ServerAddress:  options.Server,
			Options:        common.PtrValueOrDefault(options.TLS),
			KTLSCompatible: common.PtrValueOrDefault(options.Transport).Type == "",
		})
		if err != nil {
			return nil, err
		}
		h.tlsDialer = tls.NewDialer(outboundDialer, h.tlsConfig)
	}
	if options.Transport != nil {
		h.transport, err = v2ray.NewClientTransport(ctx, h.dialer, h.serverAddr, common.PtrValueOrDefault(options.Transport), h.tlsConfig)
		if err != nil {
			return nil, E.Cause(err, "create client transport: ", options.Transport.Type)
		}
	}
	return h, nil
}

func (h *Outbound) Start(stage adapter.StartStage, scope *adapter.Scope) error {
	if stage == adapter.StartStateInitialize && h.transport != nil {
		scope.Add(h.transport.Close)
	}
	return nil
}

func (h *Outbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	ctx, metadata := adapter.ExtendContext(ctx)
	metadata.Outbound = h.Tag()
	metadata.Destination = destination
	if N.NetworkName(network) != N.NetworkTCP {
		return nil, E.New("gost relay: only TCP is supported")
	}
	h.logger.InfoContext(ctx, "outbound connection to ", destination)
	var conn net.Conn
	var err error
	if h.transport != nil {
		conn, err = h.transport.DialContext(ctx)
	} else if h.tlsDialer != nil {
		conn, err = h.tlsDialer.DialTLSContext(ctx, h.serverAddr)
	} else {
		conn, err = h.dialer.DialContext(ctx, N.NetworkTCP, h.serverAddr)
	}
	if err != nil {
		common.Close(conn)
		return nil, err
	}
	header, err := buildRequest(h.username, h.password, destination)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return &clientConn{Conn: conn, header: header}, nil
}

func (h *Outbound) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	return nil, E.New("gost relay: UDP is not supported")
}

func (h *Outbound) InterfaceUpdated(ctx context.Context) {
	if h.transport != nil {
		h.transport.Close()
	}
}

// buildRequest собирает заголовок запроса CONNECT с auth (если задан) и адресом назначения.
func buildRequest(username, password string, dest M.Socksaddr) ([]byte, error) {
	var features []byte
	appendFeature := func(t byte, data []byte) {
		features = append(features, t, byte(len(data)>>8), byte(len(data)))
		features = append(features, data...)
	}
	if username != "" || password != "" {
		if len(username) > 255 || len(password) > 255 {
			return nil, E.New("gost relay: username/password too long")
		}
		data := make([]byte, 0, 2+len(username)+len(password))
		data = append(data, byte(len(username)))
		data = append(data, username...)
		data = append(data, byte(len(password)))
		data = append(data, password...)
		appendFeature(0x01, data)
	}
	var addr []byte
	switch {
	case dest.IsIPv4():
		addr = append([]byte{1}, dest.Addr.AsSlice()...)
	case dest.IsIPv6():
		addr = append([]byte{4}, dest.Addr.AsSlice()...)
	case dest.IsFqdn():
		if len(dest.Fqdn) > 255 {
			return nil, E.New("gost relay: domain too long")
		}
		addr = append([]byte{3, byte(len(dest.Fqdn))}, dest.Fqdn...)
	default:
		return nil, E.New("gost relay: bad destination")
	}
	addr = binary.BigEndian.AppendUint16(addr, dest.Port)
	appendFeature(0x02, addr)
	appendFeature(0x04, []byte{0, 0}) // network: TCP

	header := []byte{1, 1, byte(len(features) >> 8), byte(len(features))}
	return append(header, features...), nil
}

// clientConn шлёт заголовок вместе с первой записью и читает ответ при первом Read.
type clientConn struct {
	net.Conn
	header   []byte
	writeMu  sync.Mutex
	sent     bool
	readOnce sync.Once
	readErr  error
}

func (c *clientConn) flushHeader(extra []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.sent {
		return nil
	}
	c.sent = true
	_, err := c.Conn.Write(append(c.header, extra...))
	return err
}

func (c *clientConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	first := !c.sent
	c.writeMu.Unlock()
	if first {
		if err := c.flushHeader(p); err != nil {
			return 0, err
		}
		return len(p), nil
	}
	return c.Conn.Write(p)
}

func (c *clientConn) Read(p []byte) (int, error) {
	c.readOnce.Do(func() {
		if err := c.flushHeader(nil); err != nil {
			c.readErr = err
			return
		}
		var head [4]byte
		if _, err := io.ReadFull(c.Conn, head[:]); err != nil {
			c.readErr = err
			return
		}
		if head[0] != 1 {
			c.readErr = E.New("gost relay: bad version ", head[0])
			return
		}
		if n := int(binary.BigEndian.Uint16(head[2:])); n > 0 {
			if _, err := io.CopyN(io.Discard, c.Conn, int64(n)); err != nil {
				c.readErr = err
				return
			}
		}
		if head[1] != 0 {
			c.readErr = E.New("gost relay: server status ", statusText(head[1]))
		}
	})
	if c.readErr != nil {
		return 0, c.readErr
	}
	return c.Conn.Read(p)
}

func (c *clientConn) NeedHandshake() bool { return false }

func (c *clientConn) Upstream() any { return c.Conn }

func statusText(s byte) string {
	switch s {
	case 1:
		return "bad request"
	case 2:
		return "unauthorized"
	case 3:
		return "forbidden"
	case 4:
		return "timeout"
	case 5:
		return "service unavailable"
	case 6:
		return "host unreachable"
	case 7:
		return "network unreachable"
	default:
		return "internal error"
	}
}
