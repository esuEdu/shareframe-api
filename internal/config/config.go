package config

import (
	"fmt"
	"os"
	"time"
)

type Config struct {
	Env         string
	HTTPAddr    string
	DatabaseURL string
	JWTSecret   []byte

	HeartbeatInterval time.Duration
}

func Load() (Config, error) {

	c := Config{
		Env:         env("ENV", "development"),
		HTTPAddr:    env("HTTP_ADDR", ":8080"),
		DatabaseURL: env("DATABASE_URL", "postgres://vocalis:vocalis@localhost:5432/vocalis?sslmode=disable"),
	}

	if c.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	return c, nil
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
