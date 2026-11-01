# ShopPeru 

Proyecto del Grupo 15 del curso Infraestructura como Código.

Este repositorio despliega en AWS (us-east-2, entorno `dev`) una parte de la arquitectura de ShopPeru con Terraform:

- Amazon Cognito: usuarios de la tienda.
- Amazon API Gateway: ruta `GET /productos`, protegida con el token de Cognito.
- AWS Lambda (Node.js): catálogo de productos.
- CloudWatch Logs y el rol IAM de ejecución de la Lambda.

El estado de Terraform se guarda en un bucket S3 con la clave `lab09/dev/terraform.tfstate`.

## Workflows

1. `Validar Terraform`: se ejecuta con cada push o pull request a `development`. Revisa el formato y valida el código sin usar AWS.
2. `Desplegar Terraform`: se ejecuta con `workflow_run` cuando termina bien la validación de un push a `development`. Usa OIDC con el rol `lab09-github-actions-dev` y hace `terraform apply`.
3. `Destruir Terraform`: se ejecuta manualmente y hace `terraform destroy`.

El entorno `dev` de GitHub solo permite desplegar desde la rama `development` y pide aprobación antes de cada despliegue.

## Configuración en AWS

- Bucket del estado: `lab09-shopperu-tfstate-230305981121` (us-east-2), con bloqueo de acceso público, cifrado y versionado.
- Proveedor OIDC: `token.actions.githubusercontent.com` con el audience `sts.amazonaws.com`.
- Rol `lab09-github-actions-dev`: solo lo puede asumir este repositorio con el entorno `dev`. Tiene la política administrada por el cliente `lab09-terraform-dev`.
- Presupuesto mensual `lab09-presupuesto-mensual` de USD 5 con alerta por correo.

## Despliegue local

```sh
cp terraform/backend.hcl.example terraform/backend.hcl
terraform -chdir=terraform init -backend-config=backend.hcl
terraform -chdir=terraform validate
terraform -chdir=terraform plan
```
