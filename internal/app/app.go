package app

import (
	"net/http"

	"github.com/esuEdu/shareframe-api/internal/config"
)

type App struct {
	Handler http.Handler
}

func New(cfg config.Config) {

}
