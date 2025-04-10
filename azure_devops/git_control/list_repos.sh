#!/bin/bash
# ==============================================================================
# Script para Listar la Antigüedad de TODAS las Ramas en Azure DevOps
# ==============================================================================
# Descripción:
#   Itera sobre todos los repositorios de un proyecto y lista todas las ramas
#   (incluidas las protegidas), mostrando cuántos días han pasado desde el
#   último commit en cada una. Usa 'curl' para obtener datos.
# ==============================================================================

# === Configuración ===
# OBLIGATORIO: Cambia esto por tus valores reales
AZURE_ORG_NAME=" "
AZURE_PROJECT_NAME=" "
# ==========================

# --- Función de Validación Inicial ---
validate_prerequisites() {
    if ! command -v az &> /dev/null; then echo "Error Crítico: Azure CLI ('az') no encontrado."; exit 1; fi
    if ! command -v jq &> /dev/null; then echo "Error Crítico: 'jq' no encontrado."; exit 1; fi
    # 'yes' ya no es necesario porque no borramos
    # if ! command -v yes &> /dev/null; then echo "Error Crítico: Comando 'yes' no encontrado."; exit 1; fi
    if ! az account show > /dev/null 2>&1; then echo "Error Crítico: No has iniciado sesión con 'az login'."; exit 1; fi
    echo "Validación de prerrequisitos: OK"
}
# ==================================

# --- Script Principal ---
main() {
    validate_prerequisites

    # Usamos la fecha actual para los cálculos de antigüedad
    local current_time_str=$(date '+%Y-%m-%d %H:%M:%S %Z') # Fecha actual legible
    local CURRENT_EPOCH=$(date +%s)                      # Fecha actual en segundos epoch
    local SECONDS_IN_DAY=$((60*60*24))

    echo "--- Informe de Antigüedad de Ramas (Todos los Repos) ---"
    echo "Organización: $AZURE_ORG_NAME"
    echo "Proyecto:     $AZURE_PROJECT_NAME"
    echo "Fecha Actual: $current_time_str (Epoch: $CURRENT_EPOCH)"
    echo "-------------------------------------------------------"

    # --- Preparación ---
    local ORG_URL="https://dev.azure.com/$AZURE_ORG_NAME"
    local PROJECT_API_URL="$ORG_URL/$AZURE_PROJECT_NAME"
    local total_repos_processed=0
    local total_branches_processed=0
    local total_date_errors=0
    local AZ_TOKEN AUTH_HEADER

    # --- Obtener Token AAD (una sola vez para curl) ---
    echo "Obteniendo token de acceso AAD para llamadas API (curl)..."
    AZ_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken --output tsv)
    if [ -z "$AZ_TOKEN" ]; then echo "Error Crítico: No se pudo obtener el token de acceso AAD."; exit 1; fi
    AUTH_HEADER="Authorization: Bearer $AZ_TOKEN"
    echo "Token AAD obtenido."
    echo "-------------------------------------------------------"

    # --- Obtener Todos los Repositorios del Proyecto ---
    echo "Obteniendo lista de todos los repositorios en '$AZURE_PROJECT_NAME'..."
    local repos_json
    repos_json=$(az repos list --organization "$ORG_URL" --project "$AZURE_PROJECT_NAME" --output json)
    if [ $? -ne 0 ] || [ -z "$repos_json" ] || ! echo "$repos_json" | jq -e 'type == "array"' > /dev/null; then echo "Error Crítico: No se pudieron obtener repositorios."; exit 1; fi
    local repo_count
    repo_count=$(echo "$repos_json" | jq '. | length')
    if [ "$repo_count" -eq 0 ]; then echo "No se encontraron repositorios."; exit 0; fi
    echo "Se encontraron $repo_count repositorios. Iniciando análisis de ramas..."
    echo "======================================================="

    # --- Procesar cada Repositorio ---
    echo "$repos_json" | jq -c '.[] | select(.name != null and .id != null) | {name: .name, id: .id}' | while IFS= read -r repo_info; do
        local repo_name repo_id
        repo_name=$(echo "$repo_info" | jq -r '.name')
        repo_id=$(echo "$repo_info" | jq -r '.id')
        total_repos_processed=$((total_repos_processed + 1))

        echo # Línea en blanco para separar repos
        echo "--- Repositorio ($total_repos_processed/$repo_count): $repo_name ---"

        # --- Obtener Ramas y Estadísticas (usando curl) ---
        local STATS_API_URL="$PROJECT_API_URL/_apis/git/repositories/$repo_id/stats/branches?api-version=7.1-preview.1"
        local BRANCHES_JSON
        BRANCHES_JSON=$(curl -s -H "$AUTH_HEADER" "$STATS_API_URL") # Usa token AAD

        if ! echo "$BRANCHES_JSON" | jq -e '.value' > /dev/null; then
           echo "  [!] Advertencia: No se pudieron obtener estadísticas de ramas para '$repo_name'. Saltando." >&2
           continue
        fi
        local BRANCH_COUNT
        BRANCH_COUNT=$(echo "$BRANCHES_JSON" | jq '.value | length')
        if [ "$BRANCH_COUNT" -eq 0 ]; then echo "  [-] Repositorio sin ramas."; continue; fi

        # --- Analizar TODAS las Ramas e Imprimir Antigüedad ---
        local branches_processed_in_repo=0
        # Usamos < <(...) para el bucle
        while IFS= read -r branch_data; do
            local BRANCH_NAME OBJECT_ID FULL_REF_NAME
            BRANCH_NAME=$(echo "$branch_data" | jq -r '.name')
            # También obtenemos el commit ID por si es útil, aunque no lo usemos para borrar
            OBJECT_ID=$(echo "$branch_data" | jq -r '.commit.commitId')

            # Saltar si falta nombre o commit ID (indica rama inválida o sin commits)
            if [ -z "$BRANCH_NAME" ] || [ "$BRANCH_NAME" == "null" ] || [ -z "$OBJECT_ID" ] || [ "$OBJECT_ID" == "null" ]; then
                # Podríamos loggear esto si quisiéramos depurar ramas extrañas
                # echo "  [D] Saltando entrada inválida: $(echo "$branch_data" | jq -c .)" >&2
                continue
            fi
            FULL_REF_NAME="refs/heads/$BRANCH_NAME"
            total_branches_processed=$((total_branches_processed + 1))
            branches_processed_in_repo=$((branches_processed_in_repo + 1))

            # Obtener y Parsear Fecha del Último Commit
            local LAST_COMMIT_DATE_ISO LAST_COMMIT_EPOCH="" parse_error=false
            LAST_COMMIT_DATE_ISO=$(echo "$branch_data" | jq -r '.commit.committer.date')

            # Si no hay fecha de committer, la rama podría no tener commits o ser especial
            if [ -z "$LAST_COMMIT_DATE_ISO" ] || [ "$LAST_COMMIT_DATE_ISO" == "null" ]; then
                printf "  - %-50s | Último Commit: (Sin fecha de commit)\n" "$BRANCH_NAME" >&2
                continue
            fi

            # Parseo de fecha (condensado)
            local os_type=$(uname); if [[ "$os_type" == "Darwin" ]]; then if ! LAST_COMMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_COMMIT_DATE_ISO" "+%s" 2>/dev/null); then if ! LAST_COMMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_COMMIT_DATE_ISO" "+%s" 2>/dev/null); then if command -v gdate &> /dev/null; then if ! LAST_COMMIT_EPOCH=$(gdate -d "$LAST_COMMIT_DATE_ISO" +%s 2>/dev/null); then parse_error=true; fi; else parse_error=true; fi; fi; fi; else if ! LAST_COMMIT_EPOCH=$(date -d "$LAST_COMMIT_DATE_ISO" +%s 2>/dev/null); then parse_error=true; fi; fi

            # Calcular Antigüedad e Imprimir
            if $parse_error || [[ -z "$LAST_COMMIT_EPOCH" ]]; then
                printf "  - %-50s | Último Commit: ERROR parseando fecha (%s)\n" "$BRANCH_NAME" "$LAST_COMMIT_DATE_ISO" >&2
                total_date_errors=$((total_date_errors + 1))
            else
                local DIFF_SECONDS AGE_DAYS
                DIFF_SECONDS=$(( CURRENT_EPOCH - LAST_COMMIT_EPOCH ))
                # Manejar commits futuros (reloj desincronizado?) o fechas inválidas
                if [ $DIFF_SECONDS -lt 0 ]; then AGE_DAYS=-1; # Marcar como futuro/inválido
                elif [ $SECONDS_IN_DAY -eq 0 ]; then AGE_DAYS=-1; # Seguridad
                else AGE_DAYS=$(( DIFF_SECONDS / SECONDS_IN_DAY )); fi

                if [ $AGE_DAYS -eq -1 ]; then
                     printf "  - %-50s | Último Commit: Fecha futura/inválida (%s)\n" "$BRANCH_NAME" "$LAST_COMMIT_DATE_ISO"
                elif [ $AGE_DAYS -eq 0 ]; then
                     printf "  - %-50s | Último Commit: Hoy\n" "$BRANCH_NAME"
                elif [ $AGE_DAYS -eq 1 ]; then
                     printf "  - %-50s | Último Commit: Ayer (1 día)\n" "$BRANCH_NAME"
                else
                     # Usar printf para alinear la salida
                     printf "  - %-50s | Último Commit: Hace %4d días\n" "$BRANCH_NAME" "$AGE_DAYS"
                fi
            fi

        done < <(echo "$BRANCHES_JSON" | jq -c '.value[]') # Alimentar el bucle while

        echo "  [*] Analizadas $branches_processed_in_repo ramas en este repositorio."

    done # Fin bucle de repositorios

    # --- Resumen Final ---
    echo "======================================================="
    
    if [ $total_date_errors -gt 0 ]; then
        echo "Errores al Parsear Fechas: $total_date_errors (Revisar salida)" >&2
    fi
    echo "======================================================="

    exit 0
}

# --- Ejecutar el script ---
main