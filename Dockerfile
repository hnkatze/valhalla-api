# syntax=docker/dockerfile:1

# Imagen unica para la tarea de ECS: Valhalla, nginx y los docs en un solo contenedor, porque
# El template de deploy en ECS define un contenedor por tarea. En local se siguen usando los tres
# servicios separados del perfil `runtime`; esta imagen es solo para el perfil `release`.
#
# Los tiles van horneados. La imagen de Valhalla sabe descargar un .osm.pbf y construir el
# grafo, pero no sabe traerse un tile set ya construido desde S3, y reconstruirlo en cada
# arranque necesitaria GB de RAM y minutos. El pipeline los baja con scripts/pull-tiles.sh
# antes del build y quedan aqui adentro.

ARG VALHALLA_IMAGE=ghcr.io/valhalla/valhalla-scripted:3.8.3
ARG SWAGGER_IMAGE=swaggerapi/swagger-ui:v5.33.0

# Solo para extraer los archivos estaticos; esta imagen no corre en la tarea.
FROM ${SWAGGER_IMAGE} AS swagger

FROM ${VALHALLA_IMAGE}

# gettext-base trae envsubst, que el entrypoint necesita para renderizar los templates: la
# base es la de Valhalla, asi que no heredamos el entrypoint de la imagen oficial de nginx.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx gettext-base \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default

# --- Docs -------------------------------------------------------------------------------------
COPY --from=swagger /usr/share/nginx/html/ /usr/share/nginx/swagger/
COPY docs/openapi.yaml /usr/share/nginx/swagger/openapi.yaml
COPY docker/swagger-initializer.js /usr/share/nginx/swagger/swagger-initializer.js
COPY docker/swagger.conf /etc/nginx/conf.d/swagger.conf

# --- nginx ------------------------------------------------------------------------------------
COPY nginx/templates/ /etc/nginx/templates/

# --- Tiles ------------------------------------------------------------------------------------
# valhalla.json apunta a admins.sqlite y timezones.sqlite, asi que van junto al tar. Quedan
# fuera default_speeds.json y file_hashes.txt: el runtime corre con use_default_speeds_config
# en False y los hashes son metadata del build.
COPY custom_files/valhalla_tiles.tar \
     custom_files/valhalla.json \
     custom_files/admins.sqlite \
     custom_files/timezones.sqlite \
     /custom_files/

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Los upstreams viven aqui y no en la configuracion de ECS: dentro de la tarea siempre son
# localhost, asi que no hay motivo para que el equipo los tenga que definir (ni equivocarse).
# La unica variable que queda por configurar afuera es VALHALLA_TRUSTED_PROXY_CIDR.
ENV VALHALLA_UPSTREAM=http://127.0.0.1:8002 \
    VALHALLA_DOCS_UPSTREAM=http://127.0.0.1:8080 \
    VALHALLA_RESOLVER=169.254.169.253 \
    VALHALLA_TRUSTED_PROXY_CIDR=127.0.0.1 \
    NGINX_ENVSUBST_FILTER=^VALHALLA_

EXPOSE 80
WORKDIR /custom_files

# Reemplaza al entrypoint de la imagen base, que espera comandos como `build_tiles`.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
