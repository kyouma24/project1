FROM grafana/grafana-oss:12.3.1

# Metadata for traceability
LABEL maintainer="KungFu Panda" \
      description="Customized Grafana image for Business Suite" \
      version="12.3.1"

# Switch to root for build operations
USER root

##################################################################
# 1. ENVIRONMENT & FEATURE TOGGLES
##################################################################
# nestedFolders = Allows folders inside folders (Essential for large suites)
# canvasPanel   = Free-form layout tool for pixel-perfect UIs
ENV GF_ENABLE_GZIP=true \
    GF_USERS_DEFAULT_THEME=tron \
    GF_PANELS_DISABLE_SANITIZE_HTML=true \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_SNAPSHOTS_ENABLED=true \
    GF_NEWS_NEWS_FEED_ENABLED=false \
    GF_PUBLIC_DASHBOARDS_ENABLED=false \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_PATHS_PLUGINS=/var/lib/grafana/plugins \
    GF_SECURITY_ALLOW_EMBEDDING=true \
    GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/business.json \
    GF_FEATURE_TOGGLES_ENABLE="nestedFolders canvasPanel"

##################################################################
# 2. ASSETS & PROVISIONING (Optimized Copy)
##################################################################
# Create directories first to avoid permission issues later
RUN mkdir -p /etc/grafana/provisioning/dashboards \
    /var/lib/grafana/plugins \
    /usr/share/grafana/public/img

# Copy Provisioning Configs
COPY --chown=grafana:root provisioning/dashboards/ /etc/grafana/provisioning/dashboards/

# Copy Custom Branding Images
# TIP: Keep these small (SVG optimized) to keep image size down
COPY --chown=grafana:root img/neoguard.png /usr/share/grafana/public/img/fav32.png
COPY --chown=grafana:root img/neoguard.png /usr/share/grafana/public/img/apple-touch-icon.png
COPY --chown=grafana:root img/neonxt-white.svg /tmp/logo.svg
COPY --chown=grafana:root img/linux-icon.svg /usr/share/grafana/public/img/os-linux.svg
COPY --chown=grafana:root img/windows-icon.svg /usr/share/grafana/public/img/os-windows.svg
COPY --chown=grafana:root img/aws-icon.svg /usr/share/grafana/public/img/cloud-aws.svg

##################################################################
# 3. BUILD LAYER (Single RUN for Size Optimization)
##################################################################
RUN \
    # --- B. VISUAL CUSTOMIZATION ---
    # Replace the internal logo
    find /usr/share/grafana/public/build/static/img -type f -name 'grafana_icon.*.svg' \
    -exec sh -c 'cp /tmp/logo.svg "$(dirname {})/$(basename {})"' \; && \
    cp /tmp/logo.svg /usr/share/grafana/public/img/grafana_icon.svg && \
    \
    # Modify HTML Title & Loading Screen
    sed -i 's|<title>\[\[.AppTitle\]\]</title>|<title>Welcome to NeoNXT</title>|g' /usr/share/grafana/public/views/index.html && \
    sed -i 's|Loading NeoGuard|Loading NeoNXT Business Suite|g' /usr/share/grafana/public/views/index.html && \
    \
    # Inject Custom Menu Logic (The "Mega Menu" Hack)
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
    # Cleanup Nav Items
    sed -i "s|window.grafanaBootData = {| \
    nav.splice(3, 1); \
    window.grafanaBootData = {|g" \
    /usr/share/grafana/public/views/index.html && \
    \
    # --- C. JS BUNDLE RE-BRANDING ---
    find /usr/share/grafana/public/build/ -name "*.js" -type f \
    -exec sed -i 's|AppTitle="Grafana"|AppTitle="NeoNXT Cloud"|g' {} \; \
    -exec sed -i 's|LoginTitle="Welcome to Grafana"|LoginTitle=""|g' {} \; \
    -exec sed -i 's|\[{target:"_blank",id:"documentation".*grafana_footer"}\]|\[\]|g' {} \; \
    -exec sed -i 's|({target:"_blank",id:"license",.*licenseUrl})|()|g' {} \; \
    -exec sed -i 's|({target:"_blank",id:"version",text:..versionString,url:.?"https://github.com/grafana/grafana/blob/main/CHANGELOG.md":void 0})|()|g' {} \; \
    # Prevent Cloud Upsells
    -exec sed -i 's|.id==="enterprise"|.id==="notanenterprise"|g' {} \; \
    -exec sed -i 's|.id==="cloud"|.id==="notacloud"|g' {} \; && \
    \
    # --- D. CONFIGURATION UPDATES ---
    sed -i 's|\[feature_toggles\]|\[feature_toggles\]\npinNavItems=false\nonPremToCloudMigrations=false\ncorrelations=false|g' /usr/share/grafana/conf/defaults.ini && \
    \
    # --- E. SMART CLEANUP (AWS Safe) ---
    # REMOVED: cloudwatch (Kept it because you are an AWS expert)
    # REMOVED: elasticsearch (Common log source, verify if you need it)
    rm -rf \
    /usr/share/grafana/public/app/plugins/datasource/graphite \
    /usr/share/grafana/public/app/plugins/datasource/opentsdb \
    /usr/share/grafana/public/app/plugins/datasource/influxdb \
    /usr/share/grafana/public/app/plugins/datasource/mssql \
    /usr/share/grafana/public/app/plugins/datasource/tempo \
    /usr/share/grafana/public/app/plugins/datasource/jaeger \
    /usr/share/grafana/public/app/plugins/datasource/zipkin \
    /usr/share/grafana/public/app/plugins/datasource/parca \
    /usr/share/grafana/public/app/plugins/datasource/phlare \
    /usr/share/grafana/public/app/plugins/panel/news \
    /usr/share/grafana/public/app/plugins/panel/geomap \
    /usr/share/grafana/public/app/plugins/panel/table-old \
    /usr/share/grafana/public/app/plugins/panel/traces \
    /usr/share/grafana/public/app/plugins/panel/flamegraph && \
    \
    # --- F. PERMISSIONS ---
    chown -R grafana:root /usr/share/grafana/public && \
    chmod -R 755 /usr/share/grafana/public && \
    # Fix plugin permissions
    chown -R grafana:root /var/lib/grafana/plugins

##################################################################
# 4. RUNTIME SECURITY & HEALTH
##################################################################
USER grafana

# Robust Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1

EXPOSE 3000