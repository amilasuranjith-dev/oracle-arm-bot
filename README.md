# Oracle Cloud ARM Instance Auto-Retry Bot

Automated GitHub Actions workflow for provisioning an Oracle Cloud Always Free ARM instance (1 OCPU, 6 GB RAM - `VM.Standard.A1.Flex`) in the Singapore region (`ap-singapore-1`).

## Architecture & Features
- **Industry Standard Jitter & Backoff:** Uses random jitter backoff to avoid Oracle API 429 (TooManyRequests) throttling and rate limits.
- **Pre-flight Existence Check:** Queries the Oracle compute API first to see if an instance with the target display name is already in `RUNNING` or `PROVISIONING` state to prevent duplicate server charges.
- **Execution Windows:** Fits within GitHub Actions execution windows smoothly, exiting with code 1 on capacity exhaustion to let the next scheduled cron cycle seamlessly continue.
- **Immediate Exit on Success:** Stops immediately with code 0 once the instance is provisioned.
