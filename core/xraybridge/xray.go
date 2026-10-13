// Package xraybridge запускает ядро Xray внутри того же процесса, что и sing-box.
// Экспортируется через gomobile вместе с libbox (один Go-рантайм).
package xraybridge

import (
	"errors"
	"strings"
	"sync"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu       sync.Mutex
	instance *core.Instance
)

// Start запускает Xray с JSON-конфигом. Повторный вызов перезапускает ядро.
func Start(config string) error {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	if strings.TrimSpace(config) == "" {
		return errors.New("xray: empty config")
	}
	cfg, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		return err
	}
	inst, err := core.New(cfg)
	if err != nil {
		return err
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return err
	}
	instance = inst
	return nil
}

// Stop останавливает Xray.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if instance == nil {
		return nil
	}
	err := instance.Close()
	instance = nil
	return err
}

// Version возвращает версию ядра Xray.
func Version() string {
	return core.Version()
}
