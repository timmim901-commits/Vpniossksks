package option

// GostOutboundOptions — клиент протокола GOST Relay (go-gost/relay), только TCP.
type GostOutboundOptions struct {
	DialerOptions
	ServerOptions
	Username string      `json:"username,omitempty"`
	Password string      `json:"password,omitempty"`
	Network  NetworkList `json:"network,omitempty"`
	OutboundTLSOptionsContainer
	Transport *V2RayTransportOptions `json:"transport,omitempty"`
}
