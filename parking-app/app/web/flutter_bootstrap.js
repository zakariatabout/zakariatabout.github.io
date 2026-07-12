{{flutter_js}}
{{flutter_build_config}}

// CanvasKit auto-hébergé : évite la dépendance au CDN gstatic
// (réseaux d'entreprise / pays où il est bloqué).
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
