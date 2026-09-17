// Reemplaza al que trae la imagen de Swagger UI, que apunta al petstore de ejemplo y se
// reescribe en tiempo de arranque via variables de entorno (SWAGGER_JSON, BASE_URL). Aqui los
// archivos se sirven estaticos, sin ese entrypoint, asi que la configuracion va fija.
//
// La spec viaja dentro de la imagen y se sirve desde el mismo origen, por eso no hace falta CORS.
window.onload = function () {
  window.ui = SwaggerUIBundle({
    url: "/swagger/openapi.yaml",
    dom_id: "#swagger-ui",
    deepLinking: true,
    presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
    plugins: [SwaggerUIBundle.plugins.DownloadUrl],
    layout: "StandaloneLayout",
    tryItOutEnabled: true,
    persistAuthorization: true,
  });
};
