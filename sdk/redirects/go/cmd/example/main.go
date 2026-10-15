package main

import (
	"context"
	"fmt"
	"os"
	"queer.guide/redirects"
)

func main() {
	api, err := redirects.New(os.Getenv("REDIRECT_API_TOKEN"), os.Getenv("REDIRECT_API_BASE"))
	if err != nil {
		panic(err)
	}
	target := os.Getenv("REDIRECT_TARGET")
	if target == "" {
		target = "https://example.com"
	}
	ctx := context.Background()
	result, err := api.CreateLink(ctx, redirects.Object{"target": target})
	if err != nil {
		panic(err)
	}
	fmt.Println(result["link"].(map[string]any)["shortUrl"])
	if click := os.Getenv("REDIRECT_CLICK_ID"); click != "" {
		event := redirects.Object{"clickId": click, "customerExternalId": os.Getenv("REDIRECT_CUSTOMER_ID"), "eventId": os.Getenv("REDIRECT_EVENT_ID")}
		if _, err = api.TrackLead(ctx, event); err != nil {
			panic(err)
		}
		if amount := os.Getenv("REDIRECT_AMOUNT"); amount != "" {
			event["eventId"] = os.Getenv("REDIRECT_EVENT_ID") + ":sale"
			event["amount"] = amount
			event["currency"] = os.Getenv("REDIRECT_CURRENCY")
			if _, err = api.TrackSale(ctx, event); err != nil {
				panic(err)
			}
		}
	}
}
