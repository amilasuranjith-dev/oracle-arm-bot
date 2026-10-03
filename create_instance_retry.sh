#!/usr/bin/env bash

# ==============================================================================
# Oracle Cloud Always Free ARM Instance Auto-Retry Bot
# ==============================================================================
# Target: Flexible ARM Instance (VM.Standard.A1.Flex)
# High reliability, rate-limit avoidance, and automatic retry mechanism.
# ==============================================================================

set -o pipefail

# ----------------- Configuration & Environment Variables -----------------
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$OCI_TENANCY}"
AVAILABILITY_DOMAIN="${OCI_AVAILABILITY_DOMAIN:-ZptL:AP-SINGAPORE-1-AD-1}"
SUBNET_ID="${OCI_SUBNET_ID}"
IMAGE_ID="${OCI_IMAGE_ID}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCI_OCPUS:-1}"
MEMORY_IN_GBS="${OCI_MEMORY_IN_GBS:-6}"
DISPLAY_NAME="${OCI_DISPLAY_NAME:-ARM-Instance}"
HOSTNAME="${OCI_HOSTNAME:-arm-instance}"

# Max runtime duration for a single GitHub Actions run (18000s = 5 hours)
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-18000}"
START_TIME=$(date +%s)

echo "=================================================================="
echo "🚀 Oracle Cloud ARM Instance Creator Started at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Target Specs   : $OCPUS OCPU | $MEMORY_IN_GBS GB RAM ($SHAPE)"
echo "Target Region  : AP-SINGAPORE-1 ($AVAILABILITY_DOMAIN)"
echo "Display Name   : $DISPLAY_NAME"
echo "=================================================================="

# Check for mandatory parameters
if [ -z "$COMPARTMENT_ID" ] || [ -z "$SUBNET_ID" ] || [ -z "$IMAGE_ID" ]; then
    echo "❌ Error: COMPARTMENT_ID, SUBNET_ID, and IMAGE_ID must be provided."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Pre-check: Verify if an instance already exists
# ------------------------------------------------------------------------------
echo "🔍 Checking if an instance with name '$DISPLAY_NAME' already exists..."
EXISTING_INSTANCES=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$DISPLAY_NAME" \
    --lifecycle-state RUNNING \
    --lifecycle-state PROVISIONING \
    --output json 2>/dev/null)

if [ $? -eq 0 ] && [ -n "$EXISTING_INSTANCES" ]; then
    FOUND_COUNT=$(echo "$EXISTING_INSTANCES" | jq -r '.data | length' 2>/dev/null || echo 0)
    if [ "$FOUND_COUNT" -gt 0 ]; then
        EXISTING_ID=$(echo "$EXISTING_INSTANCES" | jq -r '.data[0].id')
        EXISTING_STATE=$(echo "$EXISTING_INSTANCES" | jq -r '.data[0]."lifecycle-state"')
        echo "🎉 [FOUND] Instance already exists in $EXISTING_STATE state!"
        echo "Instance OCID: $EXISTING_ID"
        echo "Exiting successfully without creating duplicates."
        exit 0
    fi
fi
echo "✓ No existing active instance found. Proceeding with creation loop."

# ------------------------------------------------------------------------------
# 2. Ensure SSH Public Key exists
# ------------------------------------------------------------------------------
if [ ! -f "$SSH_PUBLIC_KEY_FILE" ]; then
    echo "⚠️ Warning: $SSH_PUBLIC_KEY_FILE not found. Generating a fallback SSH key..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_rsa" -C "oracle-actions-runner"
fi

# ------------------------------------------------------------------------------
# 3. Main Retry Loop (Jitter Backoff & Out-of-Capacity Handling)
# ------------------------------------------------------------------------------
ATTEMPT=0

while true; do
    ATTEMPT=$((ATTEMPT + 1))
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    # Check execution window
    if [ $ELAPSED -ge $MAX_RUNTIME_SECONDS ]; then
        echo "⏳ Max execution window reached (~$((MAX_RUNTIME_SECONDS / 60)) mins, $ATTEMPT attempts made)."
        echo "Exiting with code 1. Next scheduled workflow will automatically continue."
        exit 1
    fi

    echo ""
    echo "[$ATTEMPT] Attempting instance launch at $(date -u '+%H:%M:%S UTC')..."

    # Execute OCI launch command
    LAUNCH_OUTPUT=$(oci compute instance launch \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_IN_GBS}" \
        --subnet-id "$SUBNET_ID" \
        --image-id "$IMAGE_ID" \
        --display-name "$DISPLAY_NAME" \
        --hostname-label "$HOSTNAME" \
        --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE" \
        --assign-public-ip true \
        --output json 2>&1)
    
    LAUNCH_EXIT_CODE=$?

    # Verify if provisioning or running
    if [ $LAUNCH_EXIT_CODE -eq 0 ] && [[ "$LAUNCH_OUTPUT" == *"lifecycle-state"* ]]; then
        STATE=$(echo "$LAUNCH_OUTPUT" | jq -r '.data."lifecycle-state"' 2>/dev/null || echo "PROVISIONING")
        NEW_OCID=$(echo "$LAUNCH_OUTPUT" | jq -r '.data.id' 2>/dev/null || echo "Unknown")
        
        echo "=================================================================="
        echo "🏆 SUCCESS! Instance created successfully! Status: $STATE"
        echo "Instance OCID : $NEW_OCID"
        echo "Launch Time   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Please check your Oracle Cloud Console for the Public IP."
        echo "=================================================================="
        exit 0
    fi

    # Classify error response and apply jitter delay
    if [[ "$LAUNCH_OUTPUT" =~ "TooManyRequests" ]] || [[ "$LAUNCH_OUTPUT" =~ "Too many requests" ]] || [[ "$LAUNCH_OUTPUT" =~ "429" ]]; then
        # Back off for 2-3 minutes on rate limit
        WAIT_SECONDS=$((RANDOM % 45 + 120))
        echo "⚠️ [429 TooManyRequests] Rate limit detected. Backing off for $WAIT_SECONDS seconds..."
    elif [[ "$LAUNCH_OUTPUT" =~ "Out of host capacity" ]] || [[ "$LAUNCH_OUTPUT" =~ "Out of capacity" ]]; then
        # Jitter delay between 35-55 seconds to prevent rate limit triggers
        WAIT_SECONDS=$((RANDOM % 20 + 35))
        echo "❌ [Out of host capacity] Target region currently has no free ARM capacity."
        echo "⏳ Retrying with jitter delay in $WAIT_SECONDS seconds..."
    else
        # Unknown error (e.g. invalid config, network issue)
        WAIT_SECONDS=45
        echo "⚠️ [OCI Error] Details:"
        echo "$LAUNCH_OUTPUT" | head -n 10
        echo "Waiting $WAIT_SECONDS seconds before next try..."
    fi

    sleep $WAIT_SECONDS
done
