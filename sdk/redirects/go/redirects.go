// Package redirects is a server client for queer.guide's Redirects API.
package redirects

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

type Object = map[string]any
type APIError struct {
	Status     int
	Message    string
	RetryAfter string
}

func (e *APIError) Error() string { return e.Message }

type Client struct {
	token, base string
	http        *http.Client
}

func New(token, base string) (*Client, error) {
	if strings.TrimSpace(token) == "" || strings.ContainsAny(token, "\r\n") {
		return nil, fmt.Errorf("a server credential is required")
	}
	if base == "" {
		base = "https://queer.guide/api/redirects"
	}
	u, err := url.Parse(base)
	if err != nil {
		return nil, fmt.Errorf("invalid API URL")
	}
	loopback := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Hostname() == "" || !(u.Scheme == "https" || u.Scheme == "http" && loopback) {
		return nil, fmt.Errorf("use HTTPS or a loopback development API")
	}
	return &Client{token: token, base: strings.TrimRight(base, "/"), http: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

var pathPattern = regexp.MustCompile(`^/[a-zA-Z0-9_/-]+$`)

func (c *Client) Request(ctx context.Context, method, path string, body any, query Object) (Object, error) {
	if !pathPattern.MatchString(path) || strings.Contains(path, "//") {
		return nil, fmt.Errorf("invalid API path")
	}
	u, _ := url.Parse(c.base + path)
	q := u.Query()
	for key, value := range query {
		if value == nil {
			continue
		}
		switch value.(type) {
		case map[string]any, []any:
			raw, err := json.Marshal(value)
			if err != nil {
				return nil, err
			}
			q.Set(key, string(raw))
		default:
			q.Set(key, fmt.Sprint(value))
		}
	}
	u.RawQuery = q.Encode()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	response, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 8*1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > 8*1024*1024 {
		return nil, fmt.Errorf("API response exceeds 8 MiB")
	}
	data := Object{}
	if len(raw) > 0 {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		err = decoder.Decode(&data)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message, _ := data["error"].(string)
		if message == "" {
			message = "Redirect API request failed"
		}
		return nil, &APIError{response.StatusCode, message, response.Header.Get("Retry-After")}
	}
	if err != nil || data == nil {
		return nil, fmt.Errorf("API returned invalid JSON")
	}
	return data, nil
}
func filters(value Object) Object {
	if value == nil {
		return Object{}
	}
	return value
}
func (c *Client) GetPolicy(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/links/"+id+"/policy", nil, nil)
}
func (c *Client) UpdatePolicy(ctx context.Context, id string, data Object) (Object, error) {
	return c.Request(ctx, "PATCH", "/links/"+id+"/policy", data, nil)
}
func (c *Client) GetPresentation(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/links/"+id+"/presentation", nil, nil)
}
func (c *Client) UpdatePresentation(ctx context.Context, id string, data Object) (Object, error) {
	return c.Request(ctx, "PATCH", "/links/"+id+"/presentation", data, nil)
}
func (c *Client) UploadPreviewImage(ctx context.Context, id, imageBase64 string) (Object, error) {
	return c.Request(ctx, "POST", "/links/"+id+"/preview-image", Object{"image": imageBase64}, nil)
}
func (c *Client) CreateLink(ctx context.Context, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/links", data, nil)
}
func (c *Client) GetLink(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/links/"+id, nil, nil)
}
func (c *Client) UpdateLink(ctx context.Context, id string, data Object) (Object, error) {
	return c.Request(ctx, "PATCH", "/links/"+id, data, nil)
}
func (c *Client) UpsertLink(ctx context.Context, data Object) (Object, error) {
	return c.Request(ctx, "PUT", "/links/upsert", data, nil)
}
func (c *Client) DeleteLink(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "DELETE", "/links/"+id, nil, nil)
}
func (c *Client) ListLinkedDomains(ctx context.Context, limit int, cursor string) (Object, error) {
	q := Object{"limit": limit}
	if cursor != "" {
		q["cursor"] = cursor
	}
	return c.Request(ctx, "GET", "/linked-domains", nil, q)
}
func (c *Client) GetQRStyle(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/qr-styles/links/"+url.PathEscape(id), nil, nil)
}
func (c *Client) CreateQRImage(ctx context.Context, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/qr-images", data, nil)
}
func (c *Client) ListQRImages(ctx context.Context, limit int, cursor string) (Object, error) {
	q := Object{"limit": limit}
	if cursor != "" {
		q["cursor"] = cursor
	}
	return c.Request(ctx, "GET", "/qr-images", nil, q)
}
func (c *Client) RevokeQRImage(ctx context.Context, id, version string) (Object, error) {
	return c.Request(ctx, "DELETE", "/qr-images/"+url.PathEscape(id), Object{"version": version}, nil)
}
func (c *Client) ListDomainChoices(ctx context.Context, limit int, cursor string) (Object, error) {
	q := Object{"limit": limit}
	if cursor != "" {
		q["cursor"] = cursor
	}
	return c.Request(ctx, "GET", "/domain-choices", nil, q)
}
func (c *Client) ListLinks(ctx context.Context, f Object, limit int, cursor string) (Object, error) {
	query := Object{"filters": filters(f), "limit": limit}
	if cursor != "" {
		query["cursor"] = cursor
	}
	return c.Request(ctx, "GET", "/links", nil, query)
}
func (c *Client) CountLinks(ctx context.Context, f Object) (Object, error) {
	return c.Request(ctx, "GET", "/links/count", nil, Object{"filters": filters(f)})
}
func (c *Client) Bulk(ctx context.Context, ops []Object) (Object, error) {
	return c.Request(ctx, "POST", "/links/bulk", Object{"operations": ops}, nil)
}
func (c *Client) IterateLinks(ctx context.Context, f Object, visit func(Object) error) error {
	cursor := ""
	seen := map[string]bool{}
	for {
		page, err := c.ListLinks(ctx, f, 100, cursor)
		if err != nil {
			return err
		}
		rows, ok := page["data"].([]any)
		if !ok {
			return fmt.Errorf("invalid link page")
		}
		for _, row := range rows {
			link, ok := row.(map[string]any)
			if !ok {
				return fmt.Errorf("invalid link row")
			}
			if err = visit(link); err != nil {
				return err
			}
		}
		cursor, _ = page["nextCursor"].(string)
		if cursor == "" {
			return nil
		}
		if seen[cursor] {
			return fmt.Errorf("repeated pagination cursor")
		}
		seen[cursor] = true
	}
}
func (c *Client) TrackLead(ctx context.Context, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/track/lead", data, nil)
}
func (c *Client) TrackSale(ctx context.Context, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/track/sale", data, nil)
}
func (c *Client) Analytics(ctx context.Context, f Object) (Object, error) {
	return c.Request(ctx, "GET", "/analytics", nil, Object{"filters": filters(f)})
}
func (c *Client) Events(ctx context.Context, f, options Object) (Object, error) {
	query := Object{"filters": filters(f)}
	for k, v := range options {
		if k != "filters" {
			query[k] = v
		}
	}
	return c.Request(ctx, "GET", "/events", nil, query)
}
func (c *Client) GetResource(ctx context.Context, kind, id string) (Object, error) {
	return c.Request(ctx, "GET", "/"+kind+"/"+id, nil, nil)
}
func (c *Client) ListResources(ctx context.Context, kind string, limit int, cursor string) (Object, error) {
	query := Object{"limit": limit}
	if cursor != "" {
		query["cursor"] = cursor
	}
	return c.Request(ctx, "GET", "/"+kind, nil, query)
}
func (c *Client) CreateResource(ctx context.Context, kind string, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/"+kind, data, nil)
}
func (c *Client) UpdateResource(ctx context.Context, kind, id string, data Object) (Object, error) {
	return c.Request(ctx, "PATCH", "/"+kind+"/"+id, data, nil)
}
func (c *Client) DeleteResource(ctx context.Context, kind, id string) (Object, error) {
	return c.Request(ctx, "DELETE", "/"+kind+"/"+id, nil, nil)
}

func (c *Client) CreateReport(ctx context.Context, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/reports", data, nil)
}
func (c *Client) GetReport(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/reports/"+url.PathEscape(id), nil, nil)
}
func (c *Client) ListReports(ctx context.Context, limit int, cursor string) (Object, error) {
	query := Object{"limit": limit}
	if cursor != "" {
		query["cursor"] = cursor
	}
	return c.Request(ctx, "GET", "/reports", nil, query)
}
func (c *Client) UpdateReport(ctx context.Context, id string, data Object) (Object, error) {
	return c.Request(ctx, "PATCH", "/reports/"+url.PathEscape(id), data, nil)
}
func (c *Client) DeleteReport(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "DELETE", "/reports/"+url.PathEscape(id), nil, nil)
}
func (c *Client) RunReport(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/reports/"+url.PathEscape(id)+"/run", nil, nil)
}
func (c *Client) CreateReportShare(ctx context.Context, id string, data Object) (Object, error) {
	return c.Request(ctx, "POST", "/reports/"+url.PathEscape(id)+"/shares", data, nil)
}
func (c *Client) ListReportShares(ctx context.Context, id string) (Object, error) {
	return c.Request(ctx, "GET", "/reports/"+url.PathEscape(id)+"/shares", nil, nil)
}
func (c *Client) RevokeReportShare(ctx context.Context, id, shareID string) (Object, error) {
	return c.Request(ctx, "DELETE", "/reports/"+url.PathEscape(id)+"/shares/"+url.PathEscape(shareID), nil, nil)
}
func (c *Client) ReadPublicReport(ctx context.Context, data Object) (Object, error) {
	method := "GET"
	if data != nil {
		method = "POST"
	}
	return c.Request(ctx, method, "/public-report", data, nil)
}
