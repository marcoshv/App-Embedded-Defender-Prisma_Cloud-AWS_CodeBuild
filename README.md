**Automated CI/CD Pipeline for Securing Docker Images with Prisma Cloud**
This guide provides a complete, end-to-end walkthrough for creating an automated CI/CD pipeline using AWS CodeBuild. The pipeline will pull code from a GitHub repository, embed the Prisma Cloud App-Embedded Defender into a Docker image, push the secured image to Amazon ECR, and deploy it to an Amazon EKS Fargate cluster.

This document incorporates extensive troubleshooting steps to ensure a smooth setup for a first-time user, from initial repository creation to final resource cleanup.

**Goal** 🎯
By following this guide, you will build a system that automatically:

Sets up a code repository and a serverless Kubernetes cluster.

Builds a CI/CD pipeline that securely injects the Prisma Cloud defender.

Deploys the secured application to your EKS cluster.

Prerequisites
An AWS Account

A GitHub Account

A Docker Hub Account

A Prisma Cloud Compute Account

**Step 1: Set Up Your GitHub Repository** 📁
First, we'll create a central repository for our application code and pipeline instructions.

Create a New Repository on GitHub:

Go to GitHub, click the + icon, and select New repository.

Name it (e.g., prisma-eks-pipeline), select Public, and click Create repository.

Clone the Repository Locally:

On the repository page, click the green <> Code button and copy the HTTPS URL.

Open a terminal on your computer and run:

git clone COPIED_URL_HERE
cd prisma-eks-pipeline

Create Application Files: Inside the new folder, create the following files.

Dockerfile: This file is the recipe for your container. The ENTRYPOINT is a specific requirement for the twistcli tool in our pipeline, which will be handled by a workaround in the buildspec.json file.

# Use a standard Nginx image as the base
FROM nginx:alpine

# Copy a custom index.html to the Nginx web root
COPY index.html /usr/share/nginx/html

# Expose port 80
EXPOSE 80

# Explicitly define the command to run when the container starts
ENTRYPOINT ["nginx", "-g", "daemon off;"]

index.html: A simple webpage for testing.

<!DOCTYPE html>
<html>
<head>
    <title>Secured App</title>
</head>
<body>
    <h1>This application is secured by the Prisma Cloud App-Embedded Defender!</h1>
</body>
</html>

Create a new folder named k8s. Inside it, create two files:

k8s/deployment.yaml:

apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-secure-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-secure-app
  template:
    metadata:
      labels:
        app: my-secure-app
    spec:
      containers:
      - name: my-secure-app
        image: placeholder
        ports:
        - containerPort: 80

k8s/service.yaml:

apiVersion: v1
kind: Service
metadata:
  name: my-secure-app-service
spec:
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  selector:
    app: my-secure-app

Push Files to GitHub: From your terminal, run these commands to save your work.

git add .
git commit -m "Add initial application and Kubernetes files"
git push

**Step 2: Create the EKS Fargate Cluster** 🏗️
We'll use AWS CloudShell and a tool called eksctl to easily create a serverless Kubernetes cluster.

Open AWS CloudShell: In the AWS Console, click the CloudShell icon [>_].

Install eksctl: Run these two commands in CloudShell to install the eksctl tool.

curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

Create the Cluster: Run the following command. This will take 15-20 minutes.

eksctl create cluster --name myDemoEKS --region us-east-1 --fargate

**Step 3: Securely Store All Your Credentials** 🔑
We will use AWS Secrets Manager as a digital vault for both your Prisma Cloud and Docker Hub credentials.

Create Prisma Secret:

In AWS Secrets Manager, click Store a new secret.

Select Other type of secret.

Add two key-value pairs:

Key: PRISMA_USER, Value: Your Prisma Cloud Access Key

Key: PRISMA_PASS, Value: Your Prisma Cloud Secret Key

Name the secret prisma/credentials and save it.

Create Docker Hub Secret:

In Docker Hub, go to Account Settings > Security and create a New Access Token with "Read, Write, Delete" permissions. Copy the token.

In AWS Secrets Manager, store another new secret.

Add two key-value pairs:

Key: DOCKERHUB_USER, Value: Your Docker Hub Username

Key: DOCKERHUB_PASS, Value: The Docker Hub Access Token you just generated

Name the secret dockerhub/credentials and save it.

**Step 4: Create the buildspec.json Pipeline Script** 📜
This JSON file contains our final, working pipeline instructions, including the workaround to handle the twistcli ENTRYPOINT requirement.

In your GitHub repository, click Add file > Create new file.

Name the file buildspec.json.

Copy and paste the entire code block below into the file.

{
  "version": 0.2,
  "phases": {
    "pre_build": {
      "commands": [
        "echo Logging in to Amazon ECR...",
        "aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com",
        "echo Logging in to Docker Hub...",
        "echo \"$DOCKERHUB_PASS\" | docker login --username \"$DOCKERHUB_USER\" --password-stdin"
      ]
    },
    "build": {
      "commands": [
        "echo Downloading latest Prisma Cloud twistcli...",
        "curl -k -u \"$PRISMA_USER:$PRISMA_PASS\" \"$PRISMA_CONSOLE_URL/api/v1/util/twistcli\" --output twistcli",
        "chmod +x ./twistcli",
        "echo Creating temp data folder for twistcli",
        "mkdir -p ./twistcli_data",
        "./twistcli app-embedded embed --data-folder ./twistcli_data --address $PRISMA_CONSOLE_URL --user $PRISMA_USER --password $PRISMA_PASS --app-id my-secure-app Dockerfile",
        "echo Unzipping the embedded defender package...",
        "unzip app_embedded_embed_my-secure-app.zip -d ./embedded-build",
        "echo Copying application files to the build directory...",
        "cp index.html ./embedded-build/",
        "echo Removing conflicting ENTRYPOINT from the generated Dockerfile...",
        "sed -i '/ENTRYPOINT \\[\"nginx\", \"-g\", \"daemon off;\"\\]/d' ./embedded-build/Dockerfile",
        "echo '--- Displaying final Dockerfile for debugging ---'",
        "cat ./embedded-build/Dockerfile",
        "echo '-------------------------------------------------'",
        "echo Building the secured Docker image from the modified Dockerfile...",
        "docker build -t $IMAGE_REPO_NAME:$IMAGE_TAG ./embedded-build",
        "docker tag $IMAGE_REPO_NAME:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG",
        "echo Pushing the image to ECR...",
        "docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG"
      ]
    },
    "post_build": {
      "commands": [
        "echo Configuring kubectl with IAM role for token creation...",
        "aws eks --region $AWS_REGION update-kubeconfig --name $EKS_CLUSTER_NAME",
        "echo Getting Service Account token...",
        "K8S_TOKEN=$(kubectl create token codebuild-deployer -n kube-system --duration 600s)",
        "echo Generating new kubeconfig from Service Account token...",
        "CLUSTER_ENDPOINT=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --query 'cluster.endpoint' --output text)",
        "CLUSTER_CA=$(aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --query 'cluster.certificateAuthority.data' --output text)",
        "echo \"apiVersion: v1\nclusters:\n- cluster:\n    certificate-authority-data: ${CLUSTER_CA}\n    server: ${CLUSTER_ENDPOINT}\n  name: eks-cluster\ncontexts:\n- context:\n    cluster: eks-cluster\n    user: codebuild-sa\n  name: sa-context\ncurrent-context: sa-context\nkind: Config\npreferences: {}\nusers:\n- name: codebuild-sa\n  user:\n    token: ${K8S_TOKEN}\" > /tmp/kubeconfig.yaml",
        "export KUBECONFIG=/tmp/kubeconfig.yaml",
        "echo Starting deployment to EKS Fargate...",
        "IMAGE_URL=\"$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG\"",
        "sed -i \"s|image:.*|image: $IMAGE_URL|g\" k8s/deployment.yaml",
        "echo Applying Kubernetes manifests...",
        "kubectl apply -f k8s/deployment.yaml",
        "kubectl apply -f k8s/service.yaml",
        "echo Deployment complete! 🎉"
      ]
    }
  }
}

Commit the new file.

**Step 5: Create the IAM Role for CodeBuild** 🛡️
This role grants CodeBuild the specific permissions it needs.

In IAM > Roles, click Create role.

Select AWS service and CodeBuild.

Attach these two AWS managed policies:

AmazonEC2ContainerRegistryPowerUser

AmazonEKSClusterPolicy

Name the role CodeBuild-PublicRepo-EKS-Prisma-Role and create it.

Find the role and click its name to edit it.

On the Permissions tab, Create inline policy.

Select the JSON tab and paste the following, replacing the placeholder ARNs with the actual ARNs of your secrets.

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": [
        "ARN_FOR_PRISMA_SECRET_HERE",
        "ARN_FOR_DOCKERHUB_SECRET_HERE"
      ]
    }
  ]
}

Name the policy SecretsManagerAccessPolicy and save it.

Create one more inline policy:

Service: EKS

Actions: DescribeCluster

Resources: Specific. Add the ARN for your myDemoEKS cluster.

Name it EKSDescribeClusterPermission and save.

**Step 6: Authorize IAM Principals in EKS**
This step maps your IAM user and the CodeBuild role to users inside the Kubernetes cluster, granting them administrative permissions.

Open AWS CloudShell and ensure you are connected to your cluster:

aws eks --region us-east-1 update-kubeconfig --name myDemoEKS

Find the Fargate Role ARN: eksctl created a special role for Fargate pods. Run the following command to find its exact ARN. Copy the ARN from the output.

aws iam list-roles --query 'Roles[?contains(RoleName, `FargatePodExecutionRole`)].Arn' --output text

Open the aws-auth ConfigMap for editing:

kubectl edit configmap aws-auth -n kube-system

This will open a text editor. Replace the entire contents of the file with the following YAML. You must replace all placeholders (<...>):

Paste the Fargate Role ARN you copied in the previous step.

Provide your AWS Account ID.

Provide your personal IAM user name.

# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |-
    - rolearn: <PASTE_THE_FARGATE_ROLE_ARN_YOU_FOUND_HERE>
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/CodeBuild-PublicRepo-EKS-Prisma-Role
      username: codebuild-deployer
      groups:
        - system:masters
  mapUsers: |
    - userarn: arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:user/<YOUR_IAM_USER_NAME>
      username: <YOUR_IAM_USER_NAME>
      groups:
        - system:masters

Save and close the editor. Kubernetes will apply the changes.

**Step 7: Manually Create the ECR Repository**
To prevent permissions issues, we will manually create the ECR repository.

Navigate to Elastic Container Registry (ECR).

Click Create repository.

For Repository name, enter my-secure-app.

Click Create repository.

**Step 8: Create and Authorize a Kubernetes Service Account** 🧑‍🔧
This provides the most reliable way for the pipeline to authenticate with the cluster, bypassing IAM authentication issues.

Open AWS CloudShell.

Connect to your cluster: aws eks --region us-east-1 update-kubeconfig --name myDemoEKS

Create the service account:

kubectl create serviceaccount codebuild-deployer -n kube-system

Give it cluster-admin rights:

kubectl create clusterrolebinding codebuild-deployer-binding --clusterrole=cluster-admin --serviceaccount=kube-system:codebuild-deployer

**Step 9: Create the CodeBuild Project **🏗️
This is the final step where we connect all the pieces.

In CodeBuild, click Create build project.

Project name: prisma-github-defender-pipeline

Source:

Source provider: GitHub.

Select Public repository and paste your repository's URL.

Environment:

Operating system: Ubuntu.

Runtime(s): Standard.

Image: aws/codebuild/standard:7.0 (or latest).

✅ Privileged: CHECK THIS BOX.

Service role: Choose the CodeBuild-PublicRepo-EKS-Prisma-Role you created.

Buildspec:

Select Use a buildspec file.

Buildspec name: buildspec.json.

Environment Variables: Add the following:

AWS_ACCOUNT_ID | (Plaintext) | Your 12-digit AWS Account ID

AWS_REGION | (Plaintext) | us-east-1

EKS_CLUSTER_NAME | (Plaintext) | myDemoEKS

IMAGE_REPO_NAME | (Plaintext) | my-secure-app

IMAGE_TAG | (Plaintext) | latest

PRISMA_CONSOLE_URL | (Plaintext) | Your full Prisma Console URL

PRISMA_USER | (Secrets Manager) | Full ARN of your prisma/credentials secret, ending in :PRISMA_USER

PRISMA_PASS | (Secrets Manager) | Full ARN of your prisma/credentials secret, ending in :PRISMA_PASS

DOCKERHUB_USER | (Secrets Manager) | Full ARN of your dockerhub/credentials secret, ending in :DOCKERHUB_USER

DOCKERHUB_PASS | (Secrets Manager) | Full ARN of your dockerhub/credentials secret, ending in :DOCKERHUB_PASS

Click Create build project.

**Step 10: Run the Pipeline and Verify** ✅
Navigate to your new CodeBuild project and click "Start build".

The build should succeed.

Verify the Defender Process: This is the most important check.

Open your CloudShell and get the name of a running pod: kubectl get pods

Check the processes inside the pod (replace <pod-name> with one from the previous command):

kubectl exec <pod-name> -- ps aux

Confirm that you see the twistcli_data/defender process running as PID 1.

PID   USER     TIME  COMMAND
  1 root      0:00 twistcli_data/defender app-embedded nginx -g daemon off;
 12 root      0:00 nginx: master process /usr/sbin/nginx -g daemon off;
...

Verify Application Access:

Run kubectl get services. Find the my-secure-app-service and copy its EXTERNAL-IP or HOSTNAME into your browser. You should see your secured application's webpage! 🎉

**Step 11: Clean Up All Resources** 🧹
Warning: This step will permanently delete the resources you created to stop all AWS charges. Run these commands one by one in your AWS CloudShell.

Delete the EKS Cluster (This is the most important step for cost savings and will take several minutes):

eksctl delete cluster --name myDemoEKS --region us-east-1

Delete the CodeBuild Project:

aws codebuild delete-project --name prisma-github-defender-pipeline

Delete the ECR Repository:

aws ecr delete-repository --repository-name my-secure-app --region us-east-1 --force

Delete the IAM Role:

First, detach the managed policies you attached:

aws iam detach-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam detach-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

Next, delete the inline policies you created:

aws iam delete-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-name SecretsManagerAccessPolicy
aws iam delete-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-name EKSDescribeClusterPermission

Then, find and detach policies automatically created by CodeBuild. First, list them:

aws iam list-attached-role-policies --role-name CodeBuild-PublicRepo-EKS-Prisma-Role

Now, use the ARNs from the output of the previous command to detach them. The names will be similar to this:

aws iam detach-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-arn <ARN_OF_CodeBuildSecretsManagerPolicy_HERE>
aws iam detach-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-arn <ARN_OF_CodeBuildBasePolicy_HERE>

Finally, delete the role itself. This will now succeed.

aws iam delete-role --role-name CodeBuild-PublicRepo-EKS-Prisma-Role

Delete the Secrets (Important: Replace the placeholder ARNs with the actual ARNs of your secrets):

aws secretsmanager delete-secret --secret-id ARN_FOR_PRISMA_SECRET_HERE --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id ARN_FOR_DOCKERHUB_SECRET_HERE --force-delete-without-recovery

After completing these commands, all resources for this lab will be removed.