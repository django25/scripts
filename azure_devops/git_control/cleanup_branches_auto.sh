#!/bin/bash
# ==============================================================================
# Script para Limpieza Automática de Ramas Antiguas en Azure DevOps (Todos los Repos)
# ==============================================================================
# Descripción:
#   Itera sobre todos los repositorios de un proyecto, identifica ramas antiguas
#   no protegidas (usando curl y az account token), y opcionalmente las elimina
#   usando '--object-id' y el workaround 'yes | ...' para az cli antiguo.
#
#   Incluye modo Dry Run (TEST) activado por defecto.
# ==============================================================================

# === Configuración ===
AZURE_ORG_NAME=" "
AZURE_PROJECT_NAME=" "
# Ramas a conservar siempre (separadas por coma)
PROTECTED_BRANCHES_CSV="develop,release,master,devops,main"
# Ramas sin actividad por más de estos días serán candidatas a borrado
DAYS_THRESHOLD=30
# --- Control de Ejecución ---
# true = Solo mostrar qué se borraría (RECOMENDADO PARA PROBAR)
# false = Ejecutar el borrado real (¡USAR CON PRECAUCIÓN!)
DRY_RUN=true
# ==========================

# --- Función de Validación Inicial ---
validate_prerequisites() {
    if ! command -v az &> /dev/null; then echo "Error Crítico: Azure CLI ('az') no encontrado."; exit 1; fi
    if ! command -v jq &> /dev/null; then echo "Error Crítico: 'jq' no encontrado."; exit 1; fi
    if ! command -v yes &> /dev/null; then echo "Error Crítico: Comando 'yes' no encontrado."; exit 1; fi # Necesario para el workaround
    if ! az account show > /dev/null 2>&1; then echo "Error Crítico: No has iniciado sesión con 'az login'."; exit 1; fi
    echo "Validación de prerrequisitos: OK"
}
# ==================================

# --- Script Principal ---
main() {
    validate_prerequisites

    echo "--- Limpieza Automática de Ramas Antiguas (Todos los Repos) ---"
    echo "Organización: $AZURE_ORG_NAME"
    echo "Proyecto:     $AZURE_PROJECT_NAME"
    echo "Umbral días:  $DAYS_THRESHOLD"
    echo "Protegidas:   $PROTECTED_BRANCHES_CSV"

    if $DRY_RUN; then
        echo "*** MODO SIMULACRO (Dry Run) ACTIVADO - NO SE BORRARÁ NADA ***"
    else
        echo "*** MODO REAL ACTIVADO - Las ramas candidatas SERÁN BORRADAS ***"
        read -p "ADVERTENCIA: Estás en modo REAL. Presiona Enter para continuar, o Ctrl+C para cancelar AHORA..."
    fi
    echo "-------------------------------------------"

    # --- Preparación ---
    local ORG_URL="https://dev.azure.com/$AZURE_ORG_NAME"
    local PROJECT_API_URL="$ORG_URL/$AZURE_PROJECT_NAME"
    local PROTECTED_BRANCHES_SEARCH_LOWER=$(echo ",$PROTECTED_BRANCHES_CSV," | sed 's/ *, */,/g' | tr '[:upper:]' '[:lower:]')
    local CURRENT_EPOCH=$(date +%s)
    local SECONDS_IN_DAY=$((60*60*24))
    local AZ_TOKEN AUTH_HEADER

    # --- Obtener Token AAD (una sola vez para curl) ---
    echo "Obteniendo token de acceso AAD para llamadas API (curl)..."
    AZ_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken --output tsv)
    if [ -z "$AZ_TOKEN" ]; then echo "Error Crítico: No se pudo obtener el token de acceso AAD."; exit 1; fi
    AUTH_HEADER="Authorization: Bearer $AZ_TOKEN"

    # --- Obtener Todos los Repositorios del Proyecto ---
    echo "Obteniendo lista de todos los repositorios en '$AZURE_PROJECT_NAME'..."
    local repos_json
    repos_json=$(az repos list --organization "$ORG_URL" --project "$AZURE_PROJECT_NAME" --output json)
    if [ $? -ne 0 ] || [ -z "$repos_json" ] || ! echo "$repos_json" | jq -e 'type == "array"' > /dev/null; then echo "Error: No se pudieron obtener repositorios."; exit 1; fi
    local repo_count
    repo_count=$(echo "$repos_json" | jq '. | length')
    if [ "$repo_count" -eq 0 ]; then echo "No se encontraron repositorios."; exit 0; fi
    echo "Se encontraron $repo_count repositorios."
    echo "==========================================="

    # --- Procesar cada Repositorio ---
    echo "$repos_json" | jq -c '.[] | select(.name != null and .id != null) | {name: .name, id: .id}' | while IFS= read -r repo_info; do
        local repo_name repo_id
        repo_name=$(echo "$repo_info" | jq -r '.name')
        repo_id=$(echo "$repo_info" | jq -r '.id')
        total_repos_processed=$((total_repos_processed + 1))
        local repo_candidates_found_count=0 # Contador por repo
        local repo_deleted_count=0
        local repo_error_count=0
        declare -a repo_deletable_branches=() # Array "ref;object_id" para este repo

        echo "Procesando Repositorio ($total_repos_processed/$repo_count): '$repo_name' (ID: $repo_id)"

        # --- Obtener Ramas y Estadísticas (usando curl) ---
        local STATS_API_URL="$PROJECT_API_URL/_apis/git/repositories/$repo_id/stats/branches?api-version=7.1-preview.1"
        local BRANCHES_JSON
        BRANCHES_JSON=$(curl -s -H "$AUTH_HEADER" "$STATS_API_URL") # Usa token AAD

        if ! echo "$BRANCHES_JSON" | jq -e '.value' > /dev/null; then
           echo "  [!] Advertencia: No se pudieron obtener datos de ramas para '$repo_name' (curl). Saltando."
           echo "      Respuesta API (inicio): $(echo "$BRANCHES_JSON" | head -c 100)..."
           continue
        fi
        local BRANCH_COUNT
        BRANCH_COUNT=$(echo "$BRANCHES_JSON" | jq '.value | length')
        if [ "$BRANCH_COUNT" -eq 0 ]; then echo "  [-] Repositorio sin ramas: '$repo_name'."; continue; fi
        echo "  [*] Encontradas $BRANCH_COUNT ramas. Analizando..."

        # --- Analizar Ramas (Guardando Object ID) ---
        # Iteramos sobre los datos de cada rama
        while IFS= read -r branch_data; do
            local BRANCH_NAME OBJECT_ID FULL_REF_NAME BRANCH_NAME_LOWER
            BRANCH_NAME=$(echo "$branch_data" | jq -r '.name')
            OBJECT_ID=$(echo "$branch_data" | jq -r '.commit.commitId')

            if [ -z "$BRANCH_NAME" ] || [ "$BRANCH_NAME" == "null" ] || [ -z "$OBJECT_ID" ] || [ "$OBJECT_ID" == "null" ]; then continue; fi
            FULL_REF_NAME="refs/heads/$BRANCH_NAME"
            BRANCH_NAME_LOWER=$(echo "$BRANCH_NAME" | tr '[:upper:]' '[:lower:]')

            if [[ "$PROTECTED_BRANCHES_SEARCH_LOWER" == *",$BRANCH_NAME_LOWER,"* ]]; then continue; fi

            local LAST_COMMIT_DATE_ISO LAST_COMMIT_EPOCH="" parse_error=false
            LAST_COMMIT_DATE_ISO=$(echo "$branch_data" | jq -r '.commit.committer.date')
            if [ -z "$LAST_COMMIT_DATE_ISO" ] || [ "$LAST_COMMIT_DATE_ISO" == "null" ]; then continue; fi # Saltar si falta fecha

            local os_type=$(uname); if [[ "$os_type" == "Darwin" ]]; then if ! LAST_COMMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_COMMIT_DATE_ISO" "+%s" 2>/dev/null); then if ! LAST_COMMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_COMMIT_DATE_ISO" "+%s" 2>/dev/null); then if command -v gdate &> /dev/null; then if ! LAST_COMMIT_EPOCH=$(gdate -d "$LAST_COMMIT_DATE_ISO" +%s 2>/dev/null); then parse_error=true; fi; else parse_error=true; fi; fi; fi; else if ! LAST_COMMIT_EPOCH=$(date -d "$LAST_COMMIT_DATE_ISO" +%s 2>/dev/null); then parse_error=true; fi; fi
            if $parse_error || [[ -z "$LAST_COMMIT_EPOCH" ]]; then echo "    [!] Adv: No parse fecha '$LAST_COMMIT_DATE_ISO' en '$BRANCH_NAME'"; continue; fi

            local DIFF_SECONDS AGE_DAYS
            DIFF_SECONDS=$(( CURRENT_EPOCH - LAST_COMMIT_EPOCH )); if [ $DIFF_SECONDS -lt 0 ]; then AGE_DAYS=0; elif [ $SECONDS_IN_DAY -eq 0 ]; then AGE_DAYS=0; else AGE_DAYS=$(( DIFF_SECONDS / SECONDS_IN_DAY )); fi

            if [[ "$AGE_DAYS" -gt "$DAYS_THRESHOLD" ]]; then
                echo "    -> Candidata: '$BRANCH_NAME' (Antigüedad: $AGE_DAYS días, Commit: ${OBJECT_ID:0:7})"
                repo_deletable_branches+=("$FULL_REF_NAME;$OBJECT_ID") # Guarda "ref;object_id"
                repo_candidates_found_count=$((repo_candidates_found_count + 1)) # Incrementa contador POR REPO
            fi
        done < <(echo "$BRANCHES_JSON" | jq -c '.value[] | select(.name != null and .commit.commitId != null and .commit.committer.date != null)')

        # --- Acumular contador y Borrado/Simulación para el Repositorio Actual ---
        total_candidates_found=$(( total_candidates_found + repo_candidates_found_count )) # Acumula el total global

        if [ ${#repo_deletable_branches[@]} -gt 0 ]; then
            echo "  [+] Se encontraron ${repo_candidates_found_count} ramas candidatas en '$repo_name'."

            if $DRY_RUN; then
                echo "    [DRY RUN] Las siguientes ramas SERÍAN eliminadas:"
                # Muestra solo el nombre (antes del ;)
                printf "      - %s\n" "${repo_deletable_branches[@]%;*}"
            else
                # Modo Real: Borrar ramas usando 'yes | ...' y '--object-id'
                echo "    [*] Procediendo a eliminar ${#repo_deletable_branches[@]} ramas en '$repo_name'..."
                local branch_entry branch_ref object_id error_message exit_code
                for branch_entry in "${repo_deletable_branches[@]}"; do
                    branch_ref="${branch_entry%;*}"
                    object_id="${branch_entry#*;}"

                    if [ -z "$branch_ref" ] || [ -z "$object_id" ] || [ "$branch_ref" == "$object_id" ]; then
                        echo "      ERROR INTERNO: Parseo fallido '$branch_entry'. Saltando." >&2
                        repo_error_count=$((repo_error_count + 1)); total_error_count=$((total_error_count + 1))
                        continue
                    fi

                    echo -n "      Eliminando '$branch_ref' (commit ${object_id:0:7})..."
                    # Usar 'yes |' para auto-confirmar y añadir --object-id
                    error_message=$(yes | az repos ref delete \
                        --name "$branch_ref" \
                        --object-id "$object_id" \
                        --repository "$repo_name" \
                        --organization "$ORG_URL" \
                        --project "$AZURE_PROJECT_NAME" \
                        2>&1) # --yes quitado
                    exit_code=$?
                    if [ $exit_code -eq 0 ]; then
                        echo " OK"
                        repo_deleted_count=$((repo_deleted_count + 1)); total_deleted_count=$((total_deleted_count + 1))
                    else
                        echo " ERROR!"
                        echo "        Error de Azure CLI: $error_message"
                        repo_error_count=$((repo_error_count + 1)); total_error_count=$((total_error_count + 1))
                    fi
                done
                 echo "    [*] Eliminación en '$repo_name' completada (Éxitos: $repo_deleted_count, Errores: $repo_error_count)."
            fi
        else
             echo "  [-] No se encontraron ramas candidatas en '$repo_name'."
        fi
        echo "-------------------------------------------"

    done # Fin bucle de repositorios

    # --- Resumen Final ---
    echo "==========================================="
    if $DRY_RUN; then
        echo "Modo Ejecución: Dry Run (Simulacro) - No se eliminó ninguna rama."
    else
        echo "Modo Ejecución: Real"       
    fi
    echo "==========================================="

    # Salir con código de error si hubo errores en modo real
    if ! $DRY_RUN && [ $total_error_count -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# --- Ejecutar el script ---
main