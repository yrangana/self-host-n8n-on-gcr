# Self-Hosting n8n on Google Cloud Run: Complete Guide #

This guide will walk you through the process of self-hosting n8n.io on Google Cloud Run with PostgreSQL persistence and setting up Google OAuth credentials for services like Google Sheets.

By following this guide, you'll have a fully functional n8n instance running on Google Cloud Run with PostgreSQL persistence and the ability to connect to Google services via OAuth.

## Overview ##

n8n is a powerful workflow automation platform that can be self-hosted. This guide uses:

* [Google Cloud Run](https://cloud.google.com/run?hl=en) for serverless container hosting

* [Cloud SQL PostgreSQL](https://cloud.google.com/sql/docs/postgres) for database persistence

* [Google Auth Platform](https://support.google.com/cloud/answer/15544987?hl=en) for connecting to Google services

## Prerequisites ##

Before starting, you'll need:

* A Google Cloud account

* gcloud CLI installed and configured

* Basic familiarity with Docker and command line

* A domain name (optional, but recommended for production use)

## Step 1: Set Up Your Google Cloud Project ##

First, create and configure your Google Cloud project:

```bash
# Set your Google Cloud project ID
export PROJECT_ID="your-project-id"
export REGION="europe-west2"  # Choose your preferred region

# Log in to gcloud
gcloud auth login

# Set your active project
gcloud config set project $PROJECT_ID

# Enable required APIs
gcloud services enable artifactregistry.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable sqladmin.googleapis.com
gcloud services enable secretmanager.googleapis.com
```

## Step 2: Create a Custom Dockerfile and Startup Script for n8n ##

Instead of a minimal Dockerfile, we need to create a custom setup to handle the specific requirements of running n8n on Cloud Run. This involves two files:

1. `startup.sh` - a startup script
2. `Dockerfile` - a modified Dockerfile that incorporates this script

### Why This Custom Setup is Essential ###
This customized setup solves several critical issues when running n8n on Cloud Run:

* **Port Mapping**: Cloud Run injects a PORT environment variable that containers must listen on, but n8n uses N8N_PORT instead. Our startup script bridges this gap by mapping one to the other.

* **Debugging Support**: The script outputs key environment variables, making troubleshooting much easier if deployment issues occur.

* **Permission Management**: We temporarily switch to the root user to set permissions on our script, then return to the non-root node user (a security best practice).

* **Execution Format**: Using /bin/sh explicitly helps prevent "exec format errors" that commonly occur with scripts created on different operating systems (especially Windows).

Without this custom setup, n8n would fail to start** properly in Cloud Run, and you would encounter errors like "container failed to start", or "exec format error", or "Cannot GET /".

This approach maintains compatibility with both n8n's requirements and Cloud Run's serverless container environment.

#### Troubleshooting this Step ###

If you run into issues stemming from this when building the Dockerfile you can try:

* Check the line endings of `startup.sh` are unix compatible i.e. LF (not CLRF)
* Ensure the file is executable by running `chmod +x /startup.sh` before building

## Step 3: Set Up a Container Repository ##

Create and configure a Google Artifact Registry repository:

```bash
# Create a repository in Artifact Registry
gcloud artifacts repositories create n8n-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for n8n workflow images"

# Configure Docker to use gcloud as a credential helper
gcloud auth configure-docker $REGION-docker.pkg.dev

# Build and push your image
docker build --platform linux/amd64 -t $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest .
docker push $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest
```

Note the inclusion of the `--platform` flag which is needed especially when building on an ARM architecture (e.g. Apple's M1/M2 chip) to ensure the container can run on Google Cloud Run's x86_64 architecture.

## Step 4: Set Up Cloud SQL PostgreSQL Instance ##

Create a PostgreSQL instance and database for n8n:

```bash
# Create a Cloud SQL instance (lowest cost tier)
gcloud sql instances create n8n-db \
    --database-version=POSTGRES_13 \
    --tier=db-f1-micro \
    --region=$REGION \
    --root-password="supersecure-rootpassword" \
    --storage-size=10GB \
    --availability-type=ZONAL \
    --no-backup \
    --storage-type=HDD

# Create a database
gcloud sql databases create n8n --instance=n8n-db

# Create a user for n8n
gcloud sql users create n8n-user \
    --instance=n8n-db \
    --password="supersecure-userpassword"
```

## Step 5: Create Secrets for Sensitive Data ##

Store sensitive information like passwords in Secret Manager:

```bash
# Create a secret for the database password
echo -n "supersecure-userpassword" | \
    gcloud secrets create n8n-db-password \
    --data-file=- \
    --replication-policy="automatic"

# Create a secret for n8n encryption key
echo -n "your-random-encryption-key" | \
    gcloud secrets create n8n-encryption-key \
    --data-file=- \
    --replication-policy="automatic"
```

## Step 6: Create a Service Account for Cloud Run ##

Create and configure a service account for your n8n service:

```bash
# Create a service account
gcloud iam service-accounts create n8n-service-account \
    --display-name="n8n Service Account"

# Grant access to secrets
gcloud secrets add-iam-policy-binding n8n-db-password \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding n8n-encryption-key \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

# Grant Cloud SQL Client role
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"
```

## Step 7: Deploy to Cloud Run ##

Now deploy n8n to Cloud Run with the correct environment variables:

```bash
# Get the connection name for your Cloud SQL instance
export SQL_CONNECTION=$(gcloud sql instances describe n8n-db --format="value(connectionName)")

# Deploy to Cloud Run
gcloud run deploy n8n \
    --image=$REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest \
    --platform=managed \
    --region=$REGION \
    --allow-unauthenticated \
    --port=5678 \
    --cpu=1 \
    --memory=2Gi \
    --min-instances=0 \
    --max-instances=1 \
    --set-env-vars="N8N_PATH=/,N8N_PORT=443,N8N_PROTOCOL=https,DB_TYPE=postgresdb,DB_POSTGRESDB_DATABASE=n8n,DB_POSTGRESDB_USER=n8n-user,DB_POSTGRESDB_HOST=/cloudsql/$SQL_CONNECTION,DB_POSTGRESDB_PORT=5432,DB_POSTGRESDB_SCHEMA=public,N8N_USER_FOLDER=/home/node/.n8n,EXECUTIONS_PROCESS=main,EXECUTIONS_MODE=regular,GENERIC_TIMEZONE=UTC,QUEUE_HEALTH_CHECK_ACTIVE=true" \
    --set-secrets="DB_POSTGRESDB_PASSWORD=n8n-db-password:latest,N8N_ENCRYPTION_KEY=n8n-encryption-key:latest" \
    --add-cloudsql-instances=$SQL_CONNECTION \
    --service-account=n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com
```

After deployment, Cloud Run will provide a URL for your n8n instance. Note this URL as you'll need it for the OAuth configuration.

### n8n Google Cloud Run Environment Variables ###

Below is a comprehensive table of all environment variables used in our n8n deployment on Google Cloud Run:

```md
|Environment Variable     |Value                        |Description                           |Why It's Needed                                                                                 |
|-------------------------|-----------------------------|--------------------------------------|------------------------------------------------------------------------------------------------|
|N8N_PATH                 |/                            |Base path where n8n will be accessible|Defines the root path for all n8n endpoints                                                     |
|N8N_PORT                 |443                          |External port for n8n                 |Set to 443 for proper OAuth callback URL generation (despite internal container port being 5678)|
|N8N_PROTOCOL             |https                        |Protocol used for external access     |Required for secure connections and OAuth flows                                                 |
|DB_TYPE                  |postgresdb                   |Database type for n8n                 |Must be exactly "postgresdb" (not postgresql) for proper database connection                    |
|DB_POSTGRESDB_DATABASE   |n8n                          |Name of the PostgreSQL database       |Specifies which database n8n should connect to                                                  |
|DB_POSTGRESDB_USER       |n8n-user                     |Database user name                    |Required for database authentication                                                            |
|DB_POSTGRESDB_HOST       |/cloudsql/[connection-name]  |PostgreSQL connection path            |Uses Cloud SQL Unix socket format for secure connections                                        |
|DB_POSTGRESDB_PORT       |5432                         |PostgreSQL port                       |Standard PostgreSQL port for connections                                                        |
|DB_POSTGRESDB_SCHEMA     |public                       |PostgreSQL schema                     |Required for n8n to properly initialize database tables                                         |
|N8N_USER_FOLDER          |/home/node/.n8n              |Location for n8n data                 |Defines where n8n stores workflow data and credentials                                          |
|GENERIC_TIMEZONE         |UTC                          |Default timezone                      |Ensures consistent time handling across deployments                                             |
|EXECUTIONS_PROCESS       |main                         |Execution mode for workflows          |Set to "main" for single-container deployment (vs. queue for multi-container)                   |
|EXECUTIONS_MODE          |regular                      |How executions are processed          |Controls workflow execution behavior                                                            |
|N8N_LOG_LEVEL            |debug                        |Logging verbosity                     |Set to debug for troubleshooting deployment issues                                              |
|QUEUE_HEALTH_CHECK_ACTIVE|true                         |Enables health check endpoint         |Critical for Cloud Run to verify container health                                               |
|N8N_HOST                 |[your-domain].run.app        |Public hostname of n8n                |Required for proper webhook and OAuth URL generation                                            |
|N8N_WEBHOOK_URL          |https://[your-domain].run.app|Full webhook URL                      |Needed for external services to call n8n webhooks                                               |
|N8N_EDITOR_BASE_URL      |https://[your-domain].run.app|Base URL for editor frontend          |Critical for proper OAuth redirect URL generation                                               |
|DB_POSTGRESDB_PASSWORD   |(from secret)                |Database user password                |Stored securely in Secret Manager                                                               |
|N8N_ENCRYPTION_KEY       |(from secret)                |Key for encrypting credentials        |Ensures secure storage of sensitive information in the database                                 |
```

Special Notes:

* The `PORT` variable (5678) shouldn't be explicitly set as it's injected by Cloud Run automatically

* The Cloud Run instance must map the internal container port (5678) to the port specified by Cloud Run

* Setting `N8N_PORT=443` helps generate correct external URLs while the container still listens on 5678 internally

* `QUEUE_HEALTH_CHECK_ACTIVE=true` creates an internal health endpoint that Cloud Run requires to verify container health

This configuration balances n8n's requirements with Google Cloud Run's serverless container environment.

## Step 8: Configure n8n for OAuth with Google Services ##

Once your n8n instance is running, you need to update the deployment with additional environment variables for proper OAuth functioning:

```bash
# Get your service URL (replace with your actual URL)
export SERVICE_URL="https://n8n-YOUR_ID.REGION.run.app"

# Update the deployment with proper URL configuration
gcloud run services update n8n \
    --region=$REGION \
    --set-env-vars="N8N_HOST=$(echo $SERVICE_URL | sed 's/https:\/\///'),N8N_WEBHOOK_URL=$SERVICE_URL,N8N_EDITOR_BASE_URL=$SERVICE_URL"
```

These environment variables are critical for OAuth to work correctly.

## Step 9: Set Up Google OAuth Credentials ##

To connect n8n with Google services like Google Sheets, follow these steps:

1. Access the Google Cloud Console:

    * Navigate to the Google Cloud Console

    * Select your project

2. Enable Required APIs:

    * Go to "APIs & Services" > "Library"

    * Search for and enable the APIs you need (e.g., "Google Sheets API", "Google Drive API")

3. Configure OAuth Consent Screen:

    * Go to "APIs & Services" > "OAuth consent screen"

    * Select "External" user type (or "Internal" if using Google Workspace)

    * Fill in the required information (App name, user support email, etc.)

    * Add test users if using External type

    * For scopes, add the basic "/auth/userinfo.email" and "/auth/userinfo.profile"

4. Create OAuth Client ID:

    * Go to "APIs & Services" > "Credentials"

    * Click "CREATE CREDENTIALS" and select "OAuth client ID"

    * Select "Web application" as the application type

    * Add your n8n URL to "Authorized JavaScript origins":
    
        ```bash
        https://n8n-YOUR_ID.REGION.run.app
        ```

    * When creating credentials in n8n, it will show you the required redirect URL. Add this to "Authorized redirect URIs":

        ```bash
        https://n8n-YOUR_ID.REGION.run.app/rest/oauth2-credential/callback
        ```

    * Click "CREATE" to generate your client ID and client secret

5. Add Credentials to n8n:

    * In your n8n instance, create a new credential for Google Sheets

    * Select "OAuth2" as the authentication type

    * Copy your OAuth client ID and client secret from Google Cloud Console

    * Complete the authentication flow

## Troubleshooting ##

If you encounter issues:

1. Container Fails to Start:

    * Check Cloud Run logs for specific error messages

    * Verify `DB_TYPE` is set to "postgresdb" (not "postgresql")

    * Ensure `QUEUE_HEALTH_CHECK_ACTIVE` is set to "true"

2. OAuth Redirect Issues:

    * Ensure `N8N_HOST`, `N8N_PORT`, and `N8N_EDITOR_BASE_URL` are correctly set

    * Verify redirect URIs in Google Cloud Console match exactly what n8n generates

    * Confirm `N8N_PORT` is set to 443 (not 5678) for external URL formatting

3. Database Connection Problems:

    * Check `DB_POSTGRESDB_HOST` format for Cloud SQL connections

    * Ensure service account has Cloud SQL Client role