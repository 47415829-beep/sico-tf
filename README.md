# SICO-TF · Sistema Inteligente de Control Operacional, Telemetría y Seguridad de Flota

Empresa de Transportes y Servicios El Rápido S.A. · Ruta 8105 (Carabayllo – Villa María del Triunfo)
Taller de Proyectos 1 · Equipo: Frank Huaman (Scrum Master, back-end/BD) · Frantz Urco (móvil/front-end, QA)

## Estructura del repositorio
| Carpeta | Contenido |
|---|---|
| `db/` | Script físico PostgreSQL 16 + PostGIS (3FN, datos de prueba, CRUD de referencia) |
| `backend/` | API REST + WebSocket (Node.js / Express) |
| `mobile/` | App del conductor (React Native, offline-first con SQLite) |
| `web/` | Panel del Centro de Control (React + Leaflet) |
| `.github/workflows/` | Integración continua (GitHub Actions) |

## Levantar el entorno de desarrollo
1. Instalar Docker Desktop y Git.
2. `git clone <url-del-repo> && cd sico-tf`
3. `cp .env.example .env` y completar las claves (el `.env` nunca se sube).
4. `docker compose up -d` → la base `sico_tf` se crea sola con el script de `db/`.
5. Comprobar: `docker exec -it sico-db psql -U sico_user -d sico_tf -c "select * from v_alertas_abiertas;"`

## Flujo de trabajo (Git-Flow)
- `main`: versión entregada (cada release se etiqueta: `v1.0-R1`, `v2.0-R2`).
- `develop`: integración del sprint en curso.
- `feature/HU-XX-descripcion`: una rama por historia de usuario; se integra a `develop` por Pull Request con revisión del otro integrante y CI en verde.
- `hotfix/descripcion`: correcciones urgentes sobre `main`.

## Entornos
| Entorno | Dónde | Uso |
|---|---|---|
| Desarrollo | Laptop de cada integrante (Docker) | Programar y probar cada HU |
| Pruebas | VPS en la nube, rama `develop` | Demo del sprint con el Product Owner y pruebas de aceptación |
| Producción | VPS en la nube, rama `main` | Piloto con buses de la ruta 8105 |
