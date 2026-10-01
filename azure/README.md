# register-app – Phiên bản Azure

Phiên bản này chạy song song với bản gốc (Jenkins + Docker Hub + AWS EKS) và không thay đổi bản gốc. Các dịch vụ được thay thế như sau:

| Bản gốc (AWS)          | Bản Azure                                   |
|------------------------|---------------------------------------------|
| Docker Hub             | Azure Container Registry (ACR)              |
| AWS EKS                | Azure Kubernetes Service (AKS)              |
| EC2 cho Jenkins        | Azure VM (hoặc dùng Azure DevOps Pipelines) |
| AWS credentials        | Service Principal (Microsoft Entra ID)      |
| `imagePullSecret`      | Managed identity của AKS với quyền `AcrPull` |

## Cấu trúc

```
azure/
├── Dockerfile              # Tomcat 9 + JDK 17 (tương thích javax.servlet)
├── Jenkinsfile             # Pipeline Jenkins: build → test → Sonar → Trivy → ACR → AKS
├── azure-pipelines.yml     # Phương án thay thế: Azure DevOps Pipelines
├── infra/
│   ├── main.bicep          # ACR + AKS + gán quyền AcrPull
│   ├── main.bicepparam     # Tham số mặc định
│   └── provision.sh        # Script tạo hạ tầng + Service Principal cho Jenkins
└── k8s/
    ├── deployment.yaml     # 2 replica, có readiness/liveness probe
    └── service.yaml        # LoadBalancer (IP public, cổng 80)
```

Ở thư mục gốc, `pom.xml` có thêm profile `azure` để biên dịch với Java 17 (`mvn -Pazure ...`). Build mặc định không đổi.

## 1. Tạo hạ tầng

Yêu cầu: Azure CLI đã đăng nhập (`az login`) với quyền tạo resource và gán role (Owner hoặc User Access Administrator).

```bash
# ACR_NAME phải là duy nhất trên toàn Azure (chữ thường + số, 5-50 ký tự)
ACR_NAME=myregisterappacr LOCATION=southeastasia ./azure/infra/provision.sh
```

Script sẽ:
1. Tạo resource group `register-app-rg`.
2. Deploy `main.bicep`: ACR (tắt admin user), AKS (system-assigned identity), gán `AcrPull` cho kubelet identity.
3. Tạo Service Principal `register-app-jenkins` với quyền tối thiểu: `AcrPush` trên ACR và `Azure Kubernetes Service Cluster User Role` trên AKS. Client secret chỉ được in ra một lần, hãy lưu ngay vào Jenkins và không commit vào Git.

Đặt `CREATE_JENKINS_SP=false` nếu chỉ dùng Azure DevOps.

> Lưu ý: cluster dùng local accounts (không tích hợp Entra ID), nên credential lấy từ `Cluster User Role` có toàn quyền trong cluster. Với môi trường production nên bật AKS-managed Entra ID + Azure RBAC và cài `kubelogin` trên agent.

## 2. Cập nhật tên resource

Nếu không dùng tên mặc định, sửa ở 3 chỗ:
- `azure/Jenkinsfile`: `ACR_NAME`, `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`
- `azure/azure-pipelines.yml`: `acrLoginServer`
- `azure/k8s/deployment.yaml`: `image:` (phần tag sẽ được pipeline tự thay)

## 3a. Chạy với Jenkins

Trên Jenkins agent cài thêm: Azure CLI, kubectl (Docker, Maven, JDK 17 như bản gốc).

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo az aks install-cli
```

Trong Jenkins:
1. Cài plugin **Azure Credentials**.
2. Tạo credential loại **Azure Service Principal**, ID `azure-sp`, điền Subscription ID / Client ID / Client Secret / Tenant ID từ output của `provision.sh`.
3. Giữ nguyên các credential `github` và `jenkins-sonarqube-token` như bản gốc.
4. Tạo Pipeline job, **Script Path** = `azure/Jenkinsfile`.

Các stage:

```
Checkout → Maven build (-Pazure) → Unit test → SonarQube → Quality Gate
  → az login → Docker build → Trivy scan → Push ACR → Deploy AKS (rollout status) → Cleanup
```

Khác biệt so với bản gốc:
- Trivy quét image trước khi push, image lỗi sẽ không lên registry.
- Deploy thẳng lên AKS bằng `kubectl apply` + `rollout status` thay cho việc gọi job GitOps trên EC2.

## 3b. Chạy với Azure DevOps (tùy chọn)

1. Tạo 2 service connection: `acr-connection` (Docker Registry → Azure Container Registry) và `aks-connection` (Kubernetes → Azure Subscription).
2. Tạo pipeline từ file có sẵn: `/azure/azure-pipelines.yml`.
3. Lần chạy đầu tiên sẽ tự tạo environment `register-app-aks`, có thể thêm approval cho environment này.

## 4. Kiểm tra

```bash
az aks get-credentials -g register-app-rg -n register-app-aks
kubectl get pods,svc -l app=register-app
# Mở http://<EXTERNAL-IP>/webapp/
```

## Chạy thử local

```bash
mvn -Pazure clean package
docker build -f azure/Dockerfile -t register-app:azure .
docker run --rm -p 8080:8080 register-app:azure
# http://localhost:8080/webapp/
```

## Dọn dẹp

Lệnh này xóa toàn bộ ACR, AKS và các image, không thể khôi phục:

```bash
az group delete --name register-app-rg --yes --no-wait
az ad sp delete --id <CLIENT_ID_CUA_JENKINS_SP>
```
