#!/bin/bash

# === Configuración ===
AZURE_ORG_NAME=" "
AZURE_PROJECT_NAME=" "
PROTECTED_BRANCHES_CSV="develop,release,master,devops,main"
DAYS_THRESHOLD=1
# ===================

# --- Validación Inicial ---
if ! command -v az &> /dev/null; then echo "Error: Azure CLI ('az') no encontrado."; exit 1; fi
if ! command -v jq &> /dev/null; then echo "Error: 'jq' no encontrado."; exit 1; fi
if ! az account show > /dev/null 2>&1; then echo "Error: No has iniciado sesión con 'az login'."; exit 1; fi
# ==========================

echo "--- Limpieza Interactiva de Ramas Antiguas (Workaround para az antiguo) ---"
echo "Organización: $AZURE_ORG_NAME"
echo "Proyecto:     $AZURE_PROJECT_NAME"
echo "Umbral días:  $DAYS_THRESHOLD"
echo "Protegidas:   $PROTECTED_BRANCHES_CSV"
echo "-------------------------------------------"

# --- 1. Obtener y Listar Repositorios ---
ORG_URL="https://dev.azure.com/$AZURE_ORG_NAME"
echo "Obteniendo lista de repositorios en '$AZURE_PROJECT_NAME'..."
repos_json=$(az repos list --organization "$ORG_URL" --project "$AZURE_PROJECT_NAME" --output json)
if [ $? -ne 0 ] || [ -z "$repos_json" ] || ! echo "$repos_json" | jq -e 'type == "array"' > /dev/null; then echo "Error: No se pudieron obtener repositorios."; exit 1; fi
if ! echo "$repos_json" | jq -e '.[0]' > /dev/null; then echo "No se encontraron repositorios."; exit 0; fi
echo "Repositorios disponibles:"
echo "$repos_json" | jq -r '.[] | "\(.name)"' | nl

# --- 2. Solicitar Selección de Repositorio ---
repo_count=$(echo "$repos_json" | jq '. | length')
selected_repo_index=""
while true; do read -p "Introduce el número del repo (1-$repo_count): " selected_repo_index; if [[ "$selected_repo_index" =~ ^[0-9]+$ ]] && [ "$selected_repo_index" -ge 1 ] && [ "$selected_repo_index" -le $repo_count ]; then break; else echo "Inválido."; fi; done
selected_repo_name=$(echo "$repos_json" | jq -r ".[$((selected_repo_index - 1))].name")
selected_repo_id=$(echo "$repos_json" | jq -r ".[$((selected_repo_index - 1))].id")
echo "Has seleccionado el repositorio: '$selected_repo_name' (ID: $selected_repo_id)"
echo "-------------------------------------------"

# --- 3. Obtener Token para llamadas REST (curl) ---
echo "Obteniendo token de acceso para llamadas API (curl)..."
AZ_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken --output tsv)
if [ -z "$AZ_TOKEN" ]; then echo "Error: No se pudo obtener el token de acceso AAD."; exit 1; fi
AUTH_HEADER="Authorization: Bearer $AZ_TOKEN"
PROJECT_API_URL="$ORG_URL/$AZURE_PROJECT_NAME"

# --- 4. Obtener Ramas y sus Estadísticas (usando curl) ---
STATS_API_URL="$PROJECT_API_URL/_apis/git/repositories/$selected_repo_id/stats/branches?api-version=7.1-preview.1"
echo "Obteniendo estadísticas de ramas para '$selected_repo_name' (usando curl)..."
BRANCHES_JSON=$(curl -s -H "$AUTH_HEADER" "$STATS_API_URL")
if ! echo "$BRANCHES_JSON" | jq -e '.value' > /dev/null; then echo "Advertencia: No se pudieron obtener estadísticas (curl)."; echo "Respuesta:"; echo "$BRANCHES_JSON"; exit 1; fi
BRANCH_COUNT=$(echo "$BRANCHES_JSON" | jq '.value | length')
if [ "$BRANCH_COUNT" -eq 0 ]; then echo "El repositorio '$selected_repo_name' no tiene ramas."; exit 0; fi
echo "Se encontraron $BRANCH_COUNT ramas en '$selected_repo_name'."

# --- 5. Analizar Ramas y Recopilar Candidatas (Guardando Object ID) ---
deletable_branches=()
PROTECTED_BRANCHES_SEARCH_LOWER=$(echo ",$PROTECTED_BRANCHES_CSV," | sed 's/ *, */,/g' | tr '[:upper:]' '[:lower:]')
CURRENT_EPOCH=$(date +%s)
SECONDS_IN_DAY=$((60*60*24))
echo "Analizando ramas..."
while IFS= read -r branch_data; do
    BRANCH_NAME=$(echo "$branch_data" | jq -r '.name')
    OBJECT_ID=$(echo "$branch_data" | jq -r '.commit.commitId')

    if [ -z "$BRANCH_NAME" ] || [ "$BRANCH_NAME" == "null" ] || [ -z "$OBJECT_ID" ] || [ "$OBJECT_ID" == "null" ]; then continue; fi
    FULL_REF_NAME="refs/heads/$BRANCH_NAME"
    BRANCH_NAME_LOWER=$(echo "$BRANCH_NAME" | tr '[:upper:]' '[:lower:]')

    if [[ "$PROTECTED_BRANCHES_SEARCH_LOWER" == *",$BRANCH_NAME_LOWER,"* ]]; then continue; fi

    LAST_COMMIT_DATE_ISO=$(echo "$branch_data" | jq -r '.commit.committer.date')
    LAST_COMMIT_EPOCH=""
    parse_error=false
    if [ -z "$LAST_COMMIT_DATE_ISO" ] || [ "$LAST_COMMIT_DATE_ISO" == "null" ]; then echo " - Adv: Sin fecha: '$BRANCH_NAME'"; continue; fi
    os_type=$(uname); if [[ "$os_type" == "Darwin" ]]; then if ! LAST_COMMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_COMMIT_DATE_ISO" "+%s" 2>/dev/null); then if ! LAST_COMMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_COMMIT_DATE_ISO" "+%s" 2>/dev/null); then if command -v gdate &> /dev/null; then if ! LAST_COMMIT_EPOCH=$(gdate -d "$LAST_COMMIT_DATE_ISO" +%s 2>/dev/null); then parse_error=true; fi; else parse_error=true; fi; fi; fi; else if ! LAST_COMMIT_EPOCH=$(date -d "$LAST_COMMIT_DATE_ISO" +%s 2>/dev/null); then parse_error=true; fi; fi
    if $parse_error || [[ -z "$LAST_COMMIT_EPOCH" ]]; then echo " - Adv: No parse fecha '$LAST_COMMIT_DATE_ISO' en '$BRANCH_NAME'"; continue; fi

    DIFF_SECONDS=$(( CURRENT_EPOCH - LAST_COMMIT_EPOCH )); if [ $DIFF_SECONDS -lt 0 ]; then AGE_DAYS=0; elif [ $SECONDS_IN_DAY -eq 0 ]; then AGE_DAYS=0; else AGE_DAYS=$(( DIFF_SECONDS / SECONDS_IN_DAY )); fi

    if [[ "$AGE_DAYS" -gt "$DAYS_THRESHOLD" ]]; then
        echo "  -> CANDIDATA: '$BRANCH_NAME' (Antigüedad: $AGE_DAYS días, Commit: ${OBJECT_ID:0:7})"
        deletable_branches+=("$FULL_REF_NAME;$OBJECT_ID")
    fi
done < <(echo "$BRANCHES_JSON" | jq -c '.value[] | select(.name != null and .commit.commitId != null and .commit.committer.date != null)')

# --- 6. Confirmación y Borrado (usando --object-id y 'yes | ...') ---
echo "-------------------------------------------"
if [ ${#deletable_branches[@]} -eq 0 ]; then
    echo "Análisis completado. No se encontraron ramas candidatas."
    exit 0
fi

echo "Las siguientes ${#deletable_branches[@]} ramas son CANDIDATAS para ser eliminadas:"
printf "  - %s\n" "${deletable_branches[@]%;*}"
echo "-------------------------------------------"

confirm=""
read -p "¿Deseas eliminar ESTAS ${#deletable_branches[@]} ramas del repo '$selected_repo_name'? NO se puede deshacer. (Escribe 'si' para confirmar): " confirm

if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "si" ]]; then
    echo "Procediendo con la eliminación..."
    deleted_count=0
    error_count=0
    for branch_entry in "${deletable_branches[@]}"; do
        branch_ref="${branch_entry%;*}"
        object_id="${branch_entry#*;}"

        if [ -z "$branch_ref" ] || [ -z "$object_id" ] || [ "$branch_ref" == "$object_id" ]; then
             echo "  ERROR INTERNO: No se pudo parsear '$branch_entry'. Saltando." >&2
             error_count=$((error_count + 1))
             continue
        fi

        echo -n "  Eliminando '$branch_ref' (commit ${object_id:0:7})..."
        # *** CAMBIO: Quitar --yes y añadir 'yes |' al inicio ***
        # Esto responde automáticamente 'y' a la pregunta de confirmación de 'az'
        error_message=$(yes | az repos ref delete \
            --name "$branch_ref" \
            --object-id "$object_id" \
            --repository "$selected_repo_name" \
            --organization "$ORG_URL" \
            --project "$AZURE_PROJECT_NAME" \
            2>&1) # <-- --yes ELIMINADO
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            echo " OK"
            deleted_count=$((deleted_count + 1))
        else
            # El comando 'yes' a veces puede hacer que el mensaje de error real
            # quede un poco oculto o mezclado con 'y'.
            echo " ERROR!"
            # Intentamos mostrar el mensaje de error capturado.
            echo "    Respuesta/Error de Azure CLI: $error_message"
            error_count=$((error_count + 1))
        fi
    done
    echo "-------------------------------------------"
    echo "Eliminación completada."
    echo "  Ramas eliminadas exitosamente: $deleted_count"
    echo "  Errores durante la eliminación: $error_count"
else
    echo "-------------------------------------------"
    echo "CANCELADO. No se eliminó ninguna rama."
fi

# Salir con código de error si hubo errores
if [ $error_count -gt 0 ]; then
    exit 1
else
    exit 0
fi