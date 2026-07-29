package httputil

import (
	"net/http"
	"strconv"
	"time"

	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	reqCounterVec = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"code", "method", "service"},
	)

	inFlightReqGauge = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Number of HTTP requests in flight",
		},
		[]string{"service"},
	)

	inFlightBytesGauge = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "http_requests_bytes_in_flight",
			Help: "Size in bytes of the HTTP requests in flight",
		},
		[]string{"service"},
	)

	httpReqHistogram = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name: "http_response_time_seconds",
			Help: "HTTP response times in seconds",
		},
		[]string{"code", "method", "service"},
	)
)

// ReqMonitor returns Chi middleware that tracks request count, in-flight,
// bytes in-flight, and response time histograms via Prometheus.
func ReqMonitor(serviceName string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ts := time.Now()
			ct := func() int64 {
				if r.ContentLength < 0 {
					return 0
				}
				return r.ContentLength
			}()

			inBytes := inFlightBytesGauge.With(prometheus.Labels{"service": serviceName})
			inBytes.Add(float64(ct))

			inReq := inFlightReqGauge.With(prometheus.Labels{"service": serviceName})
			inReq.Inc()

			ww := chimw.NewWrapResponseWriter(w, r.ProtoMajor)

			defer func() {
				inBytes.Sub(float64(ct))
				inReq.Dec()

				httpStatus := strconv.Itoa(ww.Status())

				reqCounterVec.With(prometheus.Labels{
					"code":    httpStatus,
					"method":  r.Method,
					"service": serviceName,
				}).Inc()

				httpReqHistogram.With(prometheus.Labels{
					"code":    httpStatus,
					"method":  r.Method,
					"service": serviceName,
				}).Observe(time.Since(ts).Seconds())
			}()

			next.ServeHTTP(ww, r)
		})
	}
}
