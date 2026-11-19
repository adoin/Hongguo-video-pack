// SPDX-License-Identifier: GPL-3.0-only
package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
)

type result struct {
	Playback *model.Playback `json:"playback,omitempty"`
	Key      string          `json:"key,omitempty"`
	Failure  string          `json:"failure,omitempty"`
}

func main() {
	out := result{Failure: "invalid_request"}
	if len(os.Args) == 3 && regexp.MustCompile(`^[0-9]{10,24}$`).MatchString(os.Args[1]) && filepath.IsAbs(os.Args[2]) {
		out = resolve(os.Args[1], os.Args[2])
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		os.Exit(1)
	}
}

func resolve(episodeID, profilePath string) result {
	client, err := adapters.NewClient(profilePath, sdk.Options{
		RetryAttempts: 1,
		DeviceResets:  sdk.Int(0),
	})
	if err != nil {
		return result{Failure: "initialization"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	playback, err := client.ResolvePlayback(ctx, episodeID, sdk.PlaybackOptions{})
	if playback == nil || (err != nil && !errors.Is(err, sdk.ErrDRMProtected)) {
		switch {
		case errors.Is(err, sdk.ErrRateLimited):
			return result{Failure: "rate_limited"}
		case errors.Is(err, sdk.ErrAuthenticationRequired):
			return result{Failure: "authentication_required"}
		case errors.Is(err, sdk.ErrContentUnavailable):
			return result{Failure: "content_unavailable"}
		default:
			return result{Failure: "model_unavailable"}
		}
	}
	reply := result{Playback: playback}
	if playback.Protected {
		key, keyErr := sdk.ContentKey(playback)
		if keyErr != nil {
			return result{Failure: "content_key"}
		}
		reply.Key = key.Hex
	}
	return reply
}
