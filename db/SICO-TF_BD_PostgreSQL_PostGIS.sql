-- =====================================================================
-- SICO-TF · Sistema Inteligente de Control Operacional, Telemetría y
-- Seguridad de Flota · Empresa de Transportes y Servicios El Rápido S.A.
-- Ruta 8105 (Carabayllo – Villa María del Triunfo)
--
-- Script físico de base de datos · PostgreSQL 16 + PostGIS 3
-- Taller de Proyectos 1 · Producto Académico N.° 2
-- Equipo: Frank Jerson Huaman Tunante · Frantz Alexander Urco Yaringaño
--
-- Criterios de diseño:
--   * Tercera Forma Normal (3FN): atributos atómicos, sin dependencias
--     parciales ni transitivas. Las relaciones N:M se resuelven con tablas
--     intermedias (ruta_paradero, checklist_despacho).
--   * Claves primarias sustitutas (IDENTITY) + claves naturales UNIQUE
--     (placa, DNI, padrón), según el caso visto en clase "Autor–Libro".
--   * Redundancia controlada: el despacho guarda el conductor, el inspector
--     y el vehículo DE ESE DÍA y la alerta guarda la posición DEL MOMENTO;
--     así el historial no cambia si luego cambian las asignaciones
--     (caso "Boleta de remuneraciones" visto en clase).
--   * Borrado lógico: catálogos con columna "activo"; las tablas
--     transaccionales (despachos, alertas, telemetría) nunca se eliminan.
--   * SRID 4326 (WGS-84, coordenadas GPS).
-- Ejecución:  psql -U postgres -f SICO-TF_BD_PostgreSQL_PostGIS.sql
-- =====================================================================

DROP DATABASE IF EXISTS sico_tf;
CREATE DATABASE sico_tf ENCODING 'UTF8';
\connect sico_tf

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), crypt()

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. SEGURIDAD Y ACCESO  (HU-04)
-- ---------------------------------------------------------------------
CREATE TABLE rol (
    rol_id       SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(30)  NOT NULL UNIQUE,
    descripcion  VARCHAR(150)
);

CREATE TABLE usuario (
    usuario_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rol_id         SMALLINT     NOT NULL REFERENCES rol(rol_id),
    dni            CHAR(8)      NOT NULL UNIQUE CHECK (dni ~ '^[0-9]{8}$'),
    nombres        VARCHAR(80)  NOT NULL,
    apellidos      VARCHAR(80)  NOT NULL,
    telefono       VARCHAR(9)   CHECK (telefono ~ '^9[0-9]{8}$'),
    email          VARCHAR(120) UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    hash_password  VARCHAR(255) NOT NULL,            -- bcrypt, nunca texto plano
    intentos_fallidos SMALLINT  NOT NULL DEFAULT 0 CHECK (intentos_fallidos BETWEEN 0 AND 5),
    activo         BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. RED DE TRANSPORTE  (HU-01, HU-06, HU-07)
-- ---------------------------------------------------------------------
CREATE TABLE ruta (
    ruta_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo     VARCHAR(10)  NOT NULL UNIQUE,          -- '8105'
    nombre     VARCHAR(120) NOT NULL,
    trazado    GEOMETRY(LineString, 4326) NOT NULL,   -- recorrido oficial (desvíos)
    tolerancia_desvio_m SMALLINT NOT NULL DEFAULT 150 CHECK (tolerancia_desvio_m BETWEEN 50 AND 500),
    activo     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE paradero (
    paradero_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(100) NOT NULL,
    es_terminal  BOOLEAN      NOT NULL DEFAULT FALSE,
    ubicacion    GEOMETRY(Point, 4326)   NOT NULL,
    geocerca     GEOMETRY(Polygon, 4326),             -- obligatoria en terminales
    activo       BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_terminal_geocerca CHECK (NOT es_terminal OR geocerca IS NOT NULL)
);

-- N:M ruta–paradero (un paradero puede servir a varias rutas)
CREATE TABLE ruta_paradero (
    ruta_paradero_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ruta_id      SMALLINT NOT NULL REFERENCES ruta(ruta_id),
    paradero_id  INTEGER  NOT NULL REFERENCES paradero(paradero_id),
    orden        SMALLINT NOT NULL CHECK (orden > 0),
    minutos_desde_inicio SMALLINT NOT NULL CHECK (minutos_desde_inicio >= 0),
    CONSTRAINT uq_ruta_orden    UNIQUE (ruta_id, orden),
    CONSTRAINT uq_ruta_paradero UNIQUE (ruta_id, paradero_id)
);

-- ---------------------------------------------------------------------
-- 3. FLOTA Y OPERACIÓN  (HU-03, HU-06, HU-08)
-- ---------------------------------------------------------------------
CREATE TABLE vehiculo (
    vehiculo_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    placa             VARCHAR(7)  NOT NULL UNIQUE CHECK (placa ~ '^[A-Z0-9]{3}-?[0-9]{3}$'),
    numero_padron     VARCHAR(10) NOT NULL UNIQUE,    -- '8105-042'
    modelo            VARCHAR(50) NOT NULL,
    anio_fabricacion  SMALLINT    NOT NULL CHECK (anio_fabricacion BETWEEN 2000 AND 2030),
    tipo_combustible  VARCHAR(10) NOT NULL CHECK (tipo_combustible IN ('GNV','DIESEL','ELECTRICO','HIBRIDO')),
    estado_operativo  VARCHAR(15) NOT NULL DEFAULT 'OPERATIVO'
                      CHECK (estado_operativo IN ('OPERATIVO','MANTENIMIENTO','BAJA')),
    activo            BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE despacho (
    despacho_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ruta_id                SMALLINT NOT NULL REFERENCES ruta(ruta_id),
    vehiculo_id            INTEGER  NOT NULL REFERENCES vehiculo(vehiculo_id),
    conductor_id           INTEGER  NOT NULL REFERENCES usuario(usuario_id),
    inspector_id           INTEGER  NOT NULL REFERENCES usuario(usuario_id),
    hora_programada_salida TIMESTAMPTZ NOT NULL,
    hora_real_salida       TIMESTAMPTZ,
    hora_real_llegada      TIMESTAMPTZ,
    estado                 VARCHAR(12) NOT NULL DEFAULT 'PROGRAMADO'
                           CHECK (estado IN ('PROGRAMADO','EN_RUTA','FINALIZADO','CANCELADO')),
    CONSTRAINT ck_conductor_inspector CHECK (conductor_id <> inspector_id),
    CONSTRAINT ck_llegada_salida      CHECK (hora_real_llegada IS NULL OR hora_real_llegada > hora_real_salida),
    CONSTRAINT ck_estado_horas        CHECK (estado <> 'FINALIZADO' OR (hora_real_salida IS NOT NULL AND hora_real_llegada IS NOT NULL))
);
-- Un vehículo no puede tener dos despachos abiertos a la vez
CREATE UNIQUE INDEX uq_despacho_abierto_vehiculo ON despacho(vehiculo_id) WHERE estado = 'EN_RUTA';
CREATE UNIQUE INDEX uq_despacho_abierto_conductor ON despacho(conductor_id) WHERE estado = 'EN_RUTA';

-- Validación de salida por QR con geocerca (HU-06)
CREATE TABLE validacion_salida (
    validacion_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    despacho_id        BIGINT  NOT NULL UNIQUE REFERENCES despacho(despacho_id),
    paradero_id        INTEGER NOT NULL REFERENCES paradero(paradero_id),
    posicion_inspector GEOMETRY(Point, 4326) NOT NULL,
    distancia_m        NUMERIC(7,1) NOT NULL CHECK (distancia_m >= 0),
    resultado          VARCHAR(10) NOT NULL CHECK (resultado IN ('APROBADA','RECHAZADA')),
    fecha_hora         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Checklist pre-despacho (HU-08): catálogo + detalle (resuelve N:M)
CREATE TABLE checklist_item (
    item_id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    descripcion  VARCHAR(120) NOT NULL UNIQUE,
    obligatorio  BOOLEAN NOT NULL DEFAULT TRUE,
    activo       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE checklist_despacho (
    checklist_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    despacho_id   BIGINT   NOT NULL REFERENCES despacho(despacho_id),
    item_id       SMALLINT NOT NULL REFERENCES checklist_item(item_id),
    conforme      BOOLEAN  NOT NULL,
    observacion   VARCHAR(200),
    CONSTRAINT uq_checklist UNIQUE (despacho_id, item_id),
    CONSTRAINT ck_obs_no_conforme CHECK (conforme OR observacion IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 4. TELEMETRÍA  (HU-01, HU-07, HU-10, HU-11)
-- ---------------------------------------------------------------------
CREATE TABLE lectura_telemetria (
    telemetria_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehiculo_id          INTEGER     NOT NULL REFERENCES vehiculo(vehiculo_id),
    fecha_hora           TIMESTAMPTZ NOT NULL,             -- hora del dispositivo
    posicion             GEOMETRY(Point, 4326) NOT NULL,
    velocidad_kmh        NUMERIC(5,1) NOT NULL CHECK (velocidad_kmh BETWEEN 0 AND 120),
    rumbo_grados         SMALLINT    CHECK (rumbo_grados BETWEEN 0 AND 359),
    precision_m          NUMERIC(5,1) NOT NULL CHECK (precision_m BETWEEN 0 AND 50),
    sincronizado_offline BOOLEAN     NOT NULL DEFAULT FALSE,
    recibido_en          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_lectura UNIQUE (vehiculo_id, fecha_hora)  -- idempotencia del reenvío offline
);
CREATE INDEX ix_telemetria_vehiculo_fecha ON lectura_telemetria (vehiculo_id, fecha_hora DESC);
CREATE INDEX ix_telemetria_posicion ON lectura_telemetria USING GIST (posicion);

-- Envío de tramas GPS a la ATU (HU-10)
CREATE TABLE envio_atu (
    envio_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    telemetria_id   BIGINT NOT NULL REFERENCES lectura_telemetria(telemetria_id),
    fecha_envio     TIMESTAMPTZ NOT NULL DEFAULT now(),
    codigo_http     SMALLINT CHECK (codigo_http BETWEEN 100 AND 599),
    estado          VARCHAR(10) NOT NULL DEFAULT 'PENDIENTE'
                    CHECK (estado IN ('PENDIENTE','ENVIADO','ERROR')),
    intentos        SMALLINT NOT NULL DEFAULT 0 CHECK (intentos BETWEEN 0 AND 10)
);

-- ---------------------------------------------------------------------
-- 5. EMERGENCIAS  (HU-02, HU-05, HU-07, HU-11)
-- ---------------------------------------------------------------------
CREATE TABLE alerta (
    alerta_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_evento_cliente    UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(), -- evita duplicados al sincronizar offline
    despacho_id          BIGINT      NOT NULL REFERENCES despacho(despacho_id),
    tipo                 VARCHAR(25) NOT NULL
                         CHECK (tipo IN ('BOTON_PANICO','DESVIO_RUTA','DETENCION_PROLONGADA')),
    origen               VARCHAR(6)  NOT NULL CHECK (origen IN ('APP','MOTOR')),
    posicion             GEOMETRY(Point, 4326) NOT NULL,   -- posición en el momento (redundancia controlada)
    fecha_hora_evento    TIMESTAMPTZ NOT NULL,
    fecha_hora_recepcion TIMESTAMPTZ NOT NULL DEFAULT now(),
    sincronizado_offline BOOLEAN     NOT NULL DEFAULT FALSE,
    estado               VARCHAR(12) NOT NULL DEFAULT 'ACTIVA'
                         CHECK (estado IN ('ACTIVA','EN_ATENCION','CERRADA','FALSA_ALARMA')),
    CONSTRAINT ck_panico_desde_app CHECK (tipo <> 'BOTON_PANICO' OR origen = 'APP'),
    CONSTRAINT ck_recepcion CHECK (fecha_hora_recepcion >= fecha_hora_evento - INTERVAL '1 minute')
);
CREATE INDEX ix_alerta_estado ON alerta (estado) WHERE estado IN ('ACTIVA','EN_ATENCION');
CREATE INDEX ix_alerta_posicion ON alerta USING GIST (posicion);

-- Historial de atención (quién hizo qué y cuándo)
CREATE TABLE atencion_alerta (
    atencion_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alerta_id     BIGINT  NOT NULL REFERENCES alerta(alerta_id),
    operador_id   INTEGER NOT NULL REFERENCES usuario(usuario_id),
    accion        VARCHAR(15) NOT NULL
                  CHECK (accion IN ('ATENDER','NOTIFICAR_PNP','CERRAR','FALSA_ALARMA')),
    observacion   VARCHAR(300),
    fecha_hora    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_obs_cierre CHECK (accion IN ('ATENDER','NOTIFICAR_PNP') OR char_length(observacion) >= 10)
);

-- =====================================================================
-- 6. LÓGICA DE NEGOCIO EN BASE DE DATOS
-- =====================================================================

-- 6.1 Validar salida QR: el inspector debe estar a ≤ 50 m del terminal (HU-06)
CREATE OR REPLACE FUNCTION fn_validar_salida(p_despacho BIGINT, p_paradero INTEGER,
                                             p_lat DOUBLE PRECISION, p_lon DOUBLE PRECISION)
RETURNS VARCHAR AS $$
DECLARE
    v_pos  GEOMETRY := ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326);
    v_dist NUMERIC;
    v_res  VARCHAR(10);
BEGIN
    IF p_lat NOT BETWEEN -90 AND 90 OR p_lon NOT BETWEEN -180 AND 180 THEN
        RAISE EXCEPTION 'Coordenadas fuera de rango';
    END IF;
    SELECT ST_Distance(ubicacion::geography, v_pos::geography) INTO v_dist
      FROM paradero WHERE paradero_id = p_paradero AND es_terminal AND activo;
    IF v_dist IS NULL THEN
        RAISE EXCEPTION 'El paradero % no es un terminal activo', p_paradero;
    END IF;
    v_res := CASE WHEN v_dist <= 50 THEN 'APROBADA' ELSE 'RECHAZADA' END;
    INSERT INTO validacion_salida(despacho_id, paradero_id, posicion_inspector, distancia_m, resultado)
    VALUES (p_despacho, p_paradero, v_pos, round(v_dist, 1), v_res);
    IF v_res = 'APROBADA' THEN
        UPDATE despacho SET estado = 'EN_RUTA', hora_real_salida = now()
         WHERE despacho_id = p_despacho AND estado = 'PROGRAMADO';
    END IF;
    RETURN v_res;
END;
$$ LANGUAGE plpgsql;

-- 6.2 Al registrar una atención, la alerta cambia de estado automáticamente (HU-05)
CREATE OR REPLACE FUNCTION fn_actualizar_estado_alerta() RETURNS TRIGGER AS $$
BEGIN
    UPDATE alerta SET estado = CASE NEW.accion
                                   WHEN 'ATENDER'       THEN 'EN_ATENCION'
                                   WHEN 'NOTIFICAR_PNP' THEN 'EN_ATENCION'
                                   WHEN 'CERRAR'        THEN 'CERRADA'
                                   WHEN 'FALSA_ALARMA'  THEN 'FALSA_ALARMA'
                               END
     WHERE alerta_id = NEW.alerta_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_atencion_alerta AFTER INSERT ON atencion_alerta
FOR EACH ROW EXECUTE FUNCTION fn_actualizar_estado_alerta();

-- 6.3 Vistas de lectura para el Centro de Control (HU-01, HU-05)
CREATE OR REPLACE VIEW v_ultima_posicion AS
SELECT DISTINCT ON (t.vehiculo_id)
       t.vehiculo_id, v.numero_padron, v.placa, t.fecha_hora, t.velocidad_kmh,
       ST_Y(t.posicion) AS lat, ST_X(t.posicion) AS lon,
       (now() - t.fecha_hora) > INTERVAL '2 minutes' AS sin_senal
  FROM lectura_telemetria t
  JOIN vehiculo v ON v.vehiculo_id = t.vehiculo_id
 ORDER BY t.vehiculo_id, t.fecha_hora DESC;

CREATE OR REPLACE VIEW v_alertas_abiertas AS
SELECT a.alerta_id, a.tipo, a.estado, a.fecha_hora_evento, a.sincronizado_offline,
       v.numero_padron, u.nombres || ' ' || u.apellidos AS conductor,
       ST_Y(a.posicion) AS lat, ST_X(a.posicion) AS lon,
       now() - a.fecha_hora_evento AS antiguedad
  FROM alerta a
  JOIN despacho d ON d.despacho_id = a.despacho_id
  JOIN vehiculo v ON v.vehiculo_id = d.vehiculo_id
  JOIN usuario  u ON u.usuario_id  = d.conductor_id
 WHERE a.estado IN ('ACTIVA','EN_ATENCION')
 ORDER BY (a.tipo = 'BOTON_PANICO') DESC, a.fecha_hora_evento;

-- =====================================================================
-- 7. DATOS INICIALES (catálogos y datos de prueba)
-- =====================================================================
INSERT INTO rol(nombre, descripcion) VALUES
 ('CONDUCTOR','Opera la app móvil en ruta'),
 ('INSPECTOR','Valida salidas en terminal'),
 ('OPERADOR','Monitorea la flota en el Centro de Control'),
 ('GERENTE','Consulta reportes e indicadores');

INSERT INTO usuario(rol_id, dni, nombres, apellidos, telefono, email, hash_password) VALUES
 (1,'70000001','Juan','Pérez Ramos','987654321','jperez@elrapido.pe', crypt('Prueba#2026', gen_salt('bf'))),
 (2,'70000002','Rosa','Quispe León','987654322','rquispe@elrapido.pe', crypt('Prueba#2026', gen_salt('bf'))),
 (3,'70000003','Luis','Torres Vega','987654323','ltorres@elrapido.pe', crypt('Prueba#2026', gen_salt('bf'))),
 (4,'70000004','Carmen','Díaz Soto','987654324','cdiaz@elrapido.pe',  crypt('Prueba#2026', gen_salt('bf')));

INSERT INTO ruta(codigo, nombre, trazado) VALUES
 ('8105','Carabayllo – Villa María del Triunfo',
  ST_GeomFromText('LINESTRING(-77.0350 -11.8530, -77.0550 -11.9450, -77.0420 -12.0460, -76.9500 -12.1600)', 4326));

INSERT INTO paradero(nombre, es_terminal, ubicacion, geocerca) VALUES
 ('Terminal Carabayllo', TRUE, ST_SetSRID(ST_MakePoint(-77.0350,-11.8530),4326),
   ST_Buffer(ST_SetSRID(ST_MakePoint(-77.0350,-11.8530),4326)::geography, 60)::geometry),
 ('Puerta Pro (Los Olivos)', FALSE, ST_SetSRID(ST_MakePoint(-77.0550,-11.9450),4326), NULL),
 ('Av. Abancay (Cercado)',   FALSE, ST_SetSRID(ST_MakePoint(-77.0420,-12.0460),4326), NULL),
 ('Terminal VMT', TRUE, ST_SetSRID(ST_MakePoint(-76.9500,-12.1600),4326),
   ST_Buffer(ST_SetSRID(ST_MakePoint(-76.9500,-12.1600),4326)::geography, 60)::geometry);

INSERT INTO ruta_paradero(ruta_id, paradero_id, orden, minutos_desde_inicio) VALUES
 (1,1,1,0),(1,2,2,35),(1,3,3,80),(1,4,4,140);

INSERT INTO vehiculo(placa, numero_padron, modelo, anio_fabricacion, tipo_combustible) VALUES
 ('B7K-042','8105-042','Modasa Titan 2', 2019, 'GNV'),
 ('B7K-089','8105-089','Modasa Titan 2', 2020, 'GNV');

INSERT INTO checklist_item(descripcion) VALUES
 ('Frenos operativos'),('Luces y direccionales'),('Extintor vigente'),
 ('Botiquín completo'),('Celular con app SICO-TF y batería ≥ 50 %');

INSERT INTO despacho(ruta_id, vehiculo_id, conductor_id, inspector_id, hora_programada_salida)
VALUES (1, 1, 1, 2, now() - INTERVAL '30 minutes');

-- =====================================================================
-- 8. OPERACIONES CRUD DE REFERENCIA (las usa la API REST)
-- =====================================================================
-- C: salida validada por geocerca (inspector a ~20 m del terminal)
SELECT fn_validar_salida(1, 1, -11.85318, -77.03500) AS resultado_qr;
-- C: lectura GPS y alerta de pánico
INSERT INTO lectura_telemetria(vehiculo_id, fecha_hora, posicion, velocidad_kmh, rumbo_grados, precision_m)
VALUES (1, now(), ST_SetSRID(ST_MakePoint(-77.0550,-11.9450),4326), 32.5, 180, 8.0);
INSERT INTO alerta(despacho_id, tipo, origen, posicion, fecha_hora_evento)
VALUES (1, 'BOTON_PANICO', 'APP', ST_SetSRID(ST_MakePoint(-77.0550,-11.9450),4326), now());
-- R: tablero del Centro de Control
SELECT numero_padron, velocidad_kmh, lat, lon FROM v_ultima_posicion;
SELECT alerta_id, tipo, estado, numero_padron, conductor FROM v_alertas_abiertas;
-- U: el operador atiende la alerta (el trigger cambia su estado)
INSERT INTO atencion_alerta(alerta_id, operador_id, accion) VALUES (1, 3, 'ATENDER');
SELECT alerta_id, estado FROM alerta;
-- U: fin de ruta (HU-03)
UPDATE despacho SET estado = 'FINALIZADO', hora_real_llegada = now() + INTERVAL '2 hours'
 WHERE despacho_id = 1;
-- D (lógico): dar de baja un vehículo sin perder su historial
UPDATE vehiculo SET activo = FALSE, estado_operativo = 'BAJA' WHERE vehiculo_id = 2;
-- Prueba de restricción (debe fallar): velocidad físicamente imposible
DO $$ BEGIN
  INSERT INTO lectura_telemetria(vehiculo_id, fecha_hora, posicion, velocidad_kmh, precision_m)
  VALUES (1, now() + INTERVAL '1 second', ST_SetSRID(ST_MakePoint(-77.05,-11.94),4326), 180, 5);
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'OK: la BD rechazó velocidad 180 km/h (regla 0–120)';
END $$;
