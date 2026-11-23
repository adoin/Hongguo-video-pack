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
	Playback *model.Playback                `json:"playback,omitempty"`
	Feed     *sdk.Page[model.SeriesSummary] `json:"feed,omitempty"`
	Key      string                         `json:"key,omitempty"`
	Failure  string                         `json:"failure,omitempty"`
}

func main() {
	out := result{Failure: "invalid_request"}
	if len(os.Args) == 3 && regexp.MustCompile(`^[0-9]{10,24}$`).MatchString(os.Args[1]) && filepath.IsAbs(os.Args[2]) {
		out = resolve(os.Args[1], os.Args[2])
	} else if len(os.Args) == 5 && os.Args[1] == "discover" && filepath.IsAbs(os.Args[2]) &&
		len(os.Args[4]) <= 4096 {
		out = discover(os.Args[2], os.Args[3], os.Args[4])
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		os.Exit(1)
	}
}

func discover(profilePath, channel, cursor string) result {
	switch channel {
	case "找剧", "首页真人剧", "首页漫剧":
	default:
		return result{Failure: "invalid_request"}
	}
	client, err := adapters.NewClient(profilePath, sdk.Options{RetryAttempts: 1, DeviceResets: sdk.Int(0)})
	if err != nil {
		return result{Failure: "initialization"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	feed, err := client.Discover(ctx, sdk.DiscoverOptions{Channel: channel, Cursor: cursor})
	if err != nil || feed == nil {
		return result{Failure: "feed_unavailable"}
	}
	return result{Feed: feed}
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
