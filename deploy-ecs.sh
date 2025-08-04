#!/bin/bash

# Script de Deploy para Amazon ECS
# Autor: Deploy Script
# Versão: 1.0

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variáveis globais
SCRIPT_NAME=$(basename "$0")
AWS_REGION="us-east-1"
ECR_REPOSITORY="bia"
ECS_CLUSTER="bia-cluster-alb"
ECS_SERVICE="service-bia-alb"
TASK_DEFINITION_FAMILY="task-def-bia-alb"
DOCKERFILE_PATH="."
ACTION=""
TARGET_COMMIT=""

# Função para mostrar ajuda
show_help() {
    cat << EOF
${BLUE}Script de Deploy para Amazon ECS${NC}

${YELLOW}USO:${NC}
    $SCRIPT_NAME [AÇÃO] [OPÇÕES]

${YELLOW}AÇÕES:${NC}
    build       Faz build da imagem Docker com tag do commit hash
    deploy      Faz deploy completo (build + deploy para ECS)
    rollback    Faz rollback para um commit específico
    list        Lista as últimas 10 task definitions
    help        Mostra esta ajuda

${YELLOW}OPÇÕES OBRIGATÓRIAS:${NC}
    -r, --region REGION              Região AWS (ex: us-east-1)
    -e, --ecr-repo REPOSITORY        Nome do repositório ECR
    -c, --cluster CLUSTER            Nome do cluster ECS
    -s, --service SERVICE            Nome do serviço ECS
    -f, --family FAMILY              Família da task definition

${YELLOW}OPÇÕES OPCIONAIS:${NC}
    -d, --dockerfile PATH            Caminho para o Dockerfile (padrão: .)
    -t, --target-commit COMMIT       Commit hash para rollback (apenas para rollback)
    -h, --help                       Mostra esta ajuda

${YELLOW}EXEMPLOS:${NC}
    # Build da imagem
    $SCRIPT_NAME build -r us-east-1 -e meu-app -c meu-cluster -s meu-service -f meu-app-task

    # Deploy completo
    $SCRIPT_NAME deploy -r us-east-1 -e meu-app -c meu-cluster -s meu-service -f meu-app-task

    # Rollback para commit específico
    $SCRIPT_NAME rollback -r us-east-1 -e meu-app -c meu-cluster -s meu-service -f meu-app-task -t abc1234

    # Listar task definitions
    $SCRIPT_NAME list -r us-east-1 -f meu-app-task

${YELLOW}PRÉ-REQUISITOS:${NC}
    - AWS CLI configurado
    - Docker instalado
    - Permissões para ECR, ECS e IAM
    - Repositório Git inicializado

EOF
}

# Função para log colorido
log() {
    local level=$1
    shift
    case $level in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $*" >&2 ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $*" >&2 ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $*" >&2 ;;
    esac
}

# Função para validar parâmetros obrigatórios
validate_required_params() {
    local missing_params=()
    
    [[ -z "$AWS_REGION" ]] && missing_params+=("--region")
    [[ -z "$ECR_REPOSITORY" ]] && missing_params+=("--ecr-repo")
    [[ -z "$TASK_DEFINITION_FAMILY" ]] && missing_params+=("--family")
    
    if [[ "$ACTION" == "deploy" || "$ACTION" == "rollback" ]]; then
        [[ -z "$ECS_CLUSTER" ]] && missing_params+=("--cluster")
        [[ -z "$ECS_SERVICE" ]] && missing_params+=("--service")
    fi
    
    if [[ "$ACTION" == "rollback" && -z "$TARGET_COMMIT" ]]; then
        missing_params+=("--target-commit")
    fi
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        log "ERROR" "Parâmetros obrigatórios faltando: ${missing_params[*]}"
        echo
        show_help
        exit 1
    fi
}

# Função para obter hash do commit
get_commit_hash() {
    local commit_ref=${1:-HEAD}
    if ! git rev-parse --verify "$commit_ref" >/dev/null 2>&1; then
        log "ERROR" "Commit '$commit_ref' não encontrado"
        exit 1
    fi
    git rev-parse --short=7 "$commit_ref"
}

# Função para fazer login no ECR
ecr_login() {
    log "INFO" "Fazendo login no ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin \
        "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com"
}

# Função para build da imagem
build_image() {
    local commit_hash
    if [[ "$ACTION" == "rollback" ]]; then
        commit_hash=$(get_commit_hash "$TARGET_COMMIT")
        log "INFO" "Fazendo checkout para commit $TARGET_COMMIT..."
        git checkout "$TARGET_COMMIT" >&2
    else
        commit_hash=$(get_commit_hash)
    fi
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local ecr_uri="$account_id.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$commit_hash"
    local image_tag="$ECR_REPOSITORY:$commit_hash"
    
    log "INFO" "Fazendo build da imagem com tag: $commit_hash"
    docker build -t "$image_tag" -t "$ecr_uri" "$DOCKERFILE_PATH" >&2
    
    log "INFO" "Fazendo push da imagem para ECR..."
    docker push "$ecr_uri" >&2
    
    echo "$ecr_uri"
}

# Função para obter task definition atual
get_current_task_definition() {
    aws ecs describe-task-definition \
        --region "$AWS_REGION" \
        --task-definition "$TASK_DEFINITION_FAMILY" \
        --query 'taskDefinition' \
        --output json 2>/dev/null || echo "{}"
}

# Função para criar nova task definition
create_task_definition() {
    local image_uri=$1
    local commit_hash=$(basename "$image_uri" | cut -d':' -f2)
    
    log "INFO" "Criando nova task definition..."
    
    # Obter task definition atual
    local current_task_def=$(get_current_task_definition)
    
    if [[ "$current_task_def" == "{}" ]]; then
        log "ERROR" "Task definition '$TASK_DEFINITION_FAMILY' não encontrada"
        log "INFO" "Criando task definition básica..."
        
        # Task definition básica para EC2
        cat > /tmp/task-definition.json << EOF
{
    "family": "$TASK_DEFINITION_FAMILY",
    "networkMode": "bridge",
    "requiresCompatibilities": ["EC2"],
    "executionRoleArn": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ecsTaskExecutionRole",
    "taskRoleArn": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "bia",
            "image": "$image_uri",
            "cpu": 0,
            "memory": 922,
            "memoryReservation": 410,
            "essential": true,
            "portMappings": [
                {
                    "containerPort": 8080,
                    "hostPort": 80,
                    "protocol": "tcp",
                    "name": "porta-80",
                    "appProtocol": "http"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/$TASK_DEFINITION_FAMILY",
                    "awslogs-create-group": "true",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
}
EOF
    else
        # Atualizar imagem na task definition existente
        echo "$current_task_def" | jq --arg image "$image_uri" \
            'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy, .enableFaultInjection) |
             .containerDefinitions[0].image = $image' > /tmp/task-definition.json
    fi
    
    # Registrar nova task definition
    local new_task_def_arn=$(aws ecs register-task-definition \
        --region "$AWS_REGION" \
        --cli-input-json file:///tmp/task-definition.json \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    log "INFO" "Nova task definition criada: $new_task_def_arn"
    echo "$new_task_def_arn"
}

# Função para atualizar serviço ECS
update_service() {
    local task_def_arn=$1
    
    log "INFO" "Atualizando serviço ECS: $ECS_SERVICE"
    aws ecs update-service \
        --region "$AWS_REGION" \
        --cluster "$ECS_CLUSTER" \
        --service "$ECS_SERVICE" \
        --task-definition "$task_def_arn" \
        --query 'service.serviceName' \
        --output text
    
    log "INFO" "Aguardando estabilização do serviço..."
    aws ecs wait services-stable \
        --region "$AWS_REGION" \
        --cluster "$ECS_CLUSTER" \
        --services "$ECS_SERVICE"
    
    log "INFO" "Serviço atualizado com sucesso!"
}

# Função para listar task definitions
list_task_definitions() {
    log "INFO" "Listando últimas 10 task definitions para família: $TASK_DEFINITION_FAMILY"
    
    aws ecs list-task-definitions \
        --region "$AWS_REGION" \
        --family-prefix "$TASK_DEFINITION_FAMILY" \
        --status ACTIVE \
        --sort DESC \
        --max-items 10 \
        --query 'taskDefinitionArns[]' \
        --output table
}

# Função principal de build
do_build() {
    log "INFO" "Iniciando processo de build..."
    ecr_login
    local image_uri=$(build_image)
    log "INFO" "Build concluído: $image_uri"
}

# Função principal de deploy
do_deploy() {
    log "INFO" "Iniciando processo de deploy..."
    ecr_login
    local image_uri=$(build_image)
    local task_def_arn=$(create_task_definition "$image_uri")
    update_service "$task_def_arn"
    log "INFO" "Deploy concluído com sucesso!"
}

# Função principal de rollback
do_rollback() {
    log "INFO" "Iniciando processo de rollback para commit: $TARGET_COMMIT"
    local current_branch=$(git branch --show-current)
    
    ecr_login
    local image_uri=$(build_image)
    local task_def_arn=$(create_task_definition "$image_uri")
    update_service "$task_def_arn"
    
    # Voltar para branch original
    if [[ -n "$current_branch" ]]; then
        log "INFO" "Voltando para branch: $current_branch"
        git checkout "$current_branch"
    fi
    
    log "INFO" "Rollback concluído com sucesso!"
}

# Parse dos argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        build|deploy|rollback|list|help)
            ACTION=$1
            shift
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPOSITORY="$2"
            shift 2
            ;;
        -c|--cluster)
            ECS_CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            ECS_SERVICE="$2"
            shift 2
            ;;
        -f|--family)
            TASK_DEFINITION_FAMILY="$2"
            shift 2
            ;;
        -d|--dockerfile)
            DOCKERFILE_PATH="$2"
            shift 2
            ;;
        -t|--target-commit)
            TARGET_COMMIT="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log "ERROR" "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se uma ação foi especificada
if [[ -z "$ACTION" ]]; then
    log "ERROR" "Nenhuma ação especificada"
    show_help
    exit 1
fi

# Mostrar ajuda se solicitado
if [[ "$ACTION" == "help" ]]; then
    show_help
    exit 0
fi

# Validar parâmetros obrigatórios
validate_required_params

# Executar ação
case $ACTION in
    build)
        do_build
        ;;
    deploy)
        do_deploy
        ;;
    rollback)
        do_rollback
        ;;
    list)
        list_task_definitions
        ;;
    *)
        log "ERROR" "Ação inválida: $ACTION"
        show_help
        exit 1
        ;;
esac
