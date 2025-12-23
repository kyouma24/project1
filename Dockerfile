FROM grafana/grafana-oss:12.3.1

# Label the image
LABEL maintainer="KungFu Panda" \
      description="Customized Grafana image for Business Suite" \
      version="12.3.1"

# Switch to root to perform modifications
USER root

##################################################################
# CONFIGURATION - Environment Variables
##################################################################
ENV GF_ENABLE_GZIP=true \
    GF_USERS_DEFAULT_THEME=tron \
    # GF_AUTH_ANONYMOUS_ENABLED=false \
    # GF_AUTH_BASIC_ENABLED=true \
    GF_PANELS_DISABLE_SANITIZE_HTML=true \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_SNAPSHOTS_ENABLED=true \
    GF_NEWS_NEWS_FEED_ENABLED=false \
    GF_PUBLIC_DASHBOARDS_ENABLED=false \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_PATHS_PLUGINS=/var/lib/grafana/plugins \
    GF_SECURITY_ALLOW_EMBEDDING=true \
    GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/business.json

# NOTE: 'tron' is not a valid standard theme. Used 'light' or 'dark' unless you have custom CSS injected.

##################################################################
# ASSETS - Copy all static assets first
##################################################################
# Copy branding images
COPY --chown=grafana:root img/neoguard.png /usr/share/grafana/public/img/fav32.png
COPY --chown=grafana:root img/neoguard.png /usr/share/grafana/public/img/apple-touch-icon.png
COPY --chown=grafana:root img/neonxt-white.svg /tmp/logo.svg

RUN mkdir -p /etc/grafana/provisioning/dashboards

COPY --chown=grafana:root provisioning/dashboards/business.json /etc/grafana/provisioning/dashboards/business.json

COPY --chown=grafana:root provisioning/dashboards/dashboards.yaml /etc/grafana/provisioning/dashboards/dashboards.yaml

# (Optional) Copy Provisioning
# COPY --chown=grafana:root provisioning/ ${GF_PATHS_PROVISIONING}/

##################################################################
# CUSTOMIZATION LOGIC - Combined Layer
##################################################################
RUN \
    # 1. VISUALS: Replace Logo dynamically in build artifacts
    find /usr/share/grafana/public/build/static/img -type f -name 'grafana_icon.*.svg' \
    -exec sh -c 'cp /tmp/logo.svg "$(dirname {})/$(basename {})"' \; && \
    cp /tmp/logo.svg /usr/share/grafana/public/img/grafana_icon.svg && \
    \
    # 2. HTML: Update Titles and Loading Text
    sed -i 's|<title>\[\[.AppTitle\]\]</title>|<title>Welcome to NeoNXT</title>|g' /usr/share/grafana/public/views/index.html && \
    sed -i 's|Loading NeoGuard|Loading NeoNXT Business Suite|g' /usr/share/grafana/public/views/index.html && \
    \
    # 3. HTML: Customize Mega Menu & Help (JavaScript Injection)
    sed -i "s|\[\[.NavTree\]\],|nav,|g; \
    s|window.grafanaBootData = {| \
    let nav = [[.NavTree]]; \
    const dashboards = nav.find((element) => element.id === 'dashboards/browse'); \
    if (dashboards) { dashboards['children'] = [];} \
    const connections = nav.find((element) => element.id === 'connections'); \
    if (connections) { connections['url'] = '/datasources'; connections['children'].shift(); } \
    const help = nav.find((element) => element.id === 'help'); \
    if (help) { help['subTitle'] = 'Business Customization 12.1.1'; help['children'] = [];} \
    window.grafanaBootData = {|g" \
    /usr/share/grafana/public/views/index.html && \
    \
    # 4. HTML: Remove items from Nav (Splice)
    sed -i "s|window.grafanaBootData = {| \
    nav.splice(3, 1); \
    window.grafanaBootData = {|g" \
    /usr/share/grafana/public/views/index.html && \
    \
    # 5. EXPERIMENTAL: Icon sizing
    sed -i 's/width: 60px;/width: 180px;/g' /usr/share/grafana/public/views/index.html && \
    sed -i 's/height: 60px;/height: 180px;/g' /usr/share/grafana/public/views/index.html && \
    \
    # 6. JS BUNDLES: Deep Branding & Cleanups
    find /usr/share/grafana/public/build/ -name "*.js" -type f \
    -exec sed -i 's|AppTitle="Grafana"|AppTitle="NeoNXT Cloud"|g' {} \; \
    -exec sed -i 's|LoginTitle="Welcome to Grafana"|LoginTitle=""|g' {} \; \
    # Remove Documentation, License, Version links
    -exec sed -i 's|\[{target:"_blank",id:"documentation".*grafana_footer"}\]|\[\]|g' {} \; \
    -exec sed -i 's|({target:"_blank",id:"license",.*licenseUrl})|()|g' {} \; \
    -exec sed -i 's|({target:"_blank",id:"version",text:..versionString,url:.?"https://github.com/grafana/grafana/blob/main/CHANGELOG.md":void 0})|()|g' {} \; \
    -exec sed -i 's|.push({target:"_blank",id:"version",text:`${..edition}${.}`,url:..licenseUrl,icon:"external-link-alt"})||g' {} \; \
    # Rename Cloud/Enterprise IDs to prevent upsells
    -exec sed -i 's|.id==="enterprise"|.id==="notanenterprise"|g' {} \; \
    -exec sed -i 's|.id==="cloud"|.id==="notacloud"|g' {} \; && \
    \
    # 7. CONFIG: Update defaults.ini
    sed -i 's|\[feature_toggles\]|\[feature_toggles\]\npinNavItems=false\nonPremToCloudMigrations=false\ncorrelations=false|g' /usr/share/grafana/conf/defaults.ini && \
    \
    # 8. CLEANUP: Remove Backend Plugins (Safer than removing Frontend Assets)
    rm -rf \
    /usr/share/grafana/public/app/plugins/datasource/elasticsearch \
    /usr/share/grafana/public/app/plugins/datasource/graphite \
    /usr/share/grafana/public/app/plugins/datasource/opentsdb \
    /usr/share/grafana/public/app/plugins/datasource/influxdb \
    /usr/share/grafana/public/app/plugins/datasource/mssql \
    /usr/share/grafana/public/app/plugins/datasource/mysql \
    /usr/share/grafana/public/app/plugins/datasource/tempo \
    /usr/share/grafana/public/app/plugins/datasource/jaeger \
    /usr/share/grafana/public/app/plugins/datasource/zipkin \
    /usr/share/grafana/public/app/plugins/datasource/azuremonitor \
    /usr/share/grafana/public/app/plugins/datasource/parca \
    /usr/share/grafana/public/app/plugins/datasource/phlare \
    /usr/share/grafana/public/app/plugins/datasource/grafana-pyroscope-datasource \
    /usr/share/grafana/public/app/plugins/panel/news \
    /usr/share/grafana/public/app/plugins/panel/geomap \
    /usr/share/grafana/public/app/plugins/panel/table-old \
    /usr/share/grafana/public/app/plugins/panel/traces \
    /usr/share/grafana/public/app/plugins/panel/flamegraph && \
    \
    # 9. PERMISSIONS: Fix permissions for the new logo and modified files
    chown -R grafana:root /usr/share/grafana/public && \
    chmod -R 755 /usr/share/grafana/public

##################################################################
# FINALIZE
##################################################################
USER grafana

# Use wget (standard in Alpine/Grafana images) instead of curl
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1

EXPOSE 3000