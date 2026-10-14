package redirects

import (
	"context"
	"errors"
	"os"
	"testing"
)

func TestSDKIntegration(t *testing.T) {
	if os.Getenv("REDIRECT_TEST_BASE") == "" {
		t.Skip("Run npm run test:redirect-sdks for the isolated edge/database fixture")
	}
	ctx := context.Background()
	api, err := New(os.Getenv("REDIRECT_TEST_TOKEN"), os.Getenv("REDIRECT_TEST_BASE"))
	if err != nil {
		t.Fatal(err)
	}
	must := func(result Object, err error) Object {
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	folder := must(api.CreateResource(ctx, "folders", Object{"name": "Héllo & + Go"}))
	tag := must(api.CreateResource(ctx, "tags", Object{"name": "Go tag", "color": "pink"}))
	template := must(api.CreateResource(ctx, "templates", Object{"name": "Go template", "parameters": Object{"utm_campaign": "Launch & +"}}))
	fid := folder["id"].(string)
	tid := tag["id"].(string)
	if must(api.UpdateResource(ctx, "folders", fid, Object{"description": "Changed"}))["description"] != "Changed" {
		t.Fatal("Folder update failed")
	}
	if must(api.UpdateResource(ctx, "tags", tid, Object{"color": "blue"}))["color"] != "blue" {
		t.Fatal("Tag update failed")
	}
	if len(must(api.ListResources(ctx, "templates", 100, ""))["data"].([]any)) != 1 {
		t.Fatal("Template list failed")
	}
	if must(api.GetResource(ctx, "folders", fid))["name"] != "Héllo & + Go" {
		t.Fatal("Unicode resource detail failed")
	}

	created := must(api.CreateLink(ctx, Object{"target": "https://example.com/?q=a%26b#detail", "slug": "sdk-go", "folderId": fid, "tagIds": []string{tid}}))
	id := created["link"].(map[string]any)["id"].(string)
	art := must(api.UploadPreviewImage(ctx, id, os.Getenv("REDIRECT_TEST_IMAGE")))
	must(api.UpdatePresentation(ctx, id, Object{"preview": Object{"title": "SDK preview", "image": art["image"], "video": "https://example.com/a.mp4"}, "cloaked": true}))
	if must(api.GetPresentation(ctx, id))["preview"].(map[string]any)["title"] != "SDK preview" {
		t.Fatal("Presentation round trip failed")
	}
	must(api.UpdateLink(ctx, id, Object{"comment": "SDK update", "isEnabled": false}))
	if must(api.GetLink(ctx, id))["folderId"] != fid {
		t.Fatal("Metadata lost")
	}
	if must(api.UpsertLink(ctx, Object{"slug": "sdk-go", "target": "/updated"}))["created"] != false {
		t.Fatal("Upsert identity lost")
	}
	if must(api.CountLinks(ctx, Object{"ids": []string{id}}))["count"].(interface{ String() string }).String() != "1" {
		t.Fatal("Count failed")
	}
	count := 0
	err = api.IterateLinks(ctx, Object{"search": "sdk-page-"}, func(Object) error { count++; return nil })
	if err != nil || count != 101 {
		t.Fatalf("Paging failed: %v %d", err, count)
	}
	batch := must(api.Bulk(ctx, []Object{{"operation": "update", "id": id, "data": Object{"comment": "Batch"}}, {"operation": "create", "data": Object{"target": "/events"}}}))
	rows := batch["data"].([]any)
	extra := rows[1].(map[string]any)["link"].(map[string]any)["id"].(string)
	must(api.DeleteLink(ctx, extra))
	lead := Object{"clickId": os.Getenv("REDIRECT_TEST_CLICK"), "customerExternalId": "go", "eventId": "sdk-lead:go"}
	must(api.TrackLead(ctx, lead))
	if must(api.TrackLead(ctx, lead))["duplicate"] != true {
		t.Fatal("Retry dedupe failed")
	}
	lead["eventId"] = "sdk-sale:go"
	lead["amount"] = "49.900001"
	lead["currency"] = "CHF"
	must(api.TrackSale(ctx, lead))
	if must(api.Analytics(ctx, Object{"country": "CH"}))["totals"] == nil {
		t.Fatal("Analytics failed")
	}
	if len(must(api.Events(ctx, nil, Object{"limit": 1}))["data"].([]any)) != 1 {
		t.Fatal("Events failed")
	}
	must(api.DeleteLink(ctx, id))
	for kind, item := range map[string]Object{"folders": folder, "tags": tag, "templates": template} {
		must(api.DeleteResource(ctx, kind, item["id"].(string)))
	}
	for path, status := range map[string]int{"/redirect-probe": 302, "/limited-probe": 429} {
		_, err := api.Request(ctx, "GET", path, nil, nil)
		var apiError *APIError
		if !errors.As(err, &apiError) || apiError.Status != status {
			t.Fatalf("Expected API status %d: %v", status, err)
		}
		if status == 429 && apiError.RetryAfter != "17" {
			t.Fatal("Retry header lost")
		}
	}
	if _, err := New("token", "http://example.com/api"); err == nil {
		t.Fatal("Insecure base accepted")
	}
}
