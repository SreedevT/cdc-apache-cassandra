#!/bin/bash

###############################################################################
# CDC Apache Cassandra - Test Runner Script
# This script makes it easy to run E2E tests locally
###############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
PULSAR_IMAGE="datastax/lunastreaming"
PULSAR_TAG="4.0_3.6"
CLEAN_BUILD=false
VERBOSE=false
OPEN_REPORT=true

###############################################################################
# Functions
###############################################################################

print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker not found. Please install Docker."
        exit 1
    fi
    print_success "Docker found: $(docker --version)"
    
    # Check Docker is running
    if ! docker ps &> /dev/null; then
        print_error "Docker daemon not running. Please start Docker."
        exit 1
    fi
    print_success "Docker daemon is running"
    
    # Check Docker socket
    if [ ! -S /var/run/docker.sock ]; then
        print_warning "Standard Docker socket not found at /var/run/docker.sock"
        if [ -S ~/.rd/docker.sock ]; then
            print_info "Rancher Desktop socket found. Creating symlink..."
            sudo ln -sf ~/.rd/docker.sock /var/run/docker.sock
            print_success "Symlink created"
        else
            print_error "Docker socket not found. Tests may fail."
        fi
    else
        print_success "Docker socket accessible"
    fi
    
    # Check Java
    if ! command -v java &> /dev/null; then
        print_error "Java not found. Please install Java 11 or 17."
        exit 1
    fi
    print_success "Java found: $(java -version 2>&1 | head -1)"
    
    # Check Docker resources
    TOTAL_MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{print int($1/1024/1024/1024)}')
    if [ "$TOTAL_MEM" -lt 4 ]; then
        print_warning "Docker has only ${TOTAL_MEM}GB memory. Tests may be slow or fail."
        print_info "Recommended: 6-8GB. Increase in Docker Desktop settings."
    else
        print_success "Docker has ${TOTAL_MEM}GB memory"
    fi
    
    echo ""
}

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [TEST_TARGET]

Run CDC Apache Cassandra E2E tests locally.

TEST_TARGET:
    agent-c5       Run Cassandra 5 agent tests (default)
    agent-c4       Run Cassandra 4 agent tests
    agent-c3       Run Cassandra 3 agent tests
    connector      Run connector tests
    all            Run all tests
    
OPTIONS:
    -c, --clean           Clean build before testing
    -v, --verbose         Show verbose Gradle output
    -n, --no-report       Don't open HTML report after tests
    -p, --pulsar IMAGE    Pulsar image (default: datastax/lunastreaming)
    -t, --tag TAG         Pulsar image tag (default: 4.0_3.6)
    --test NAME           Run specific test class
    --debug               Run with debug logging
    --info                Show Gradle info logs
    -h, --help            Show this help message

EXAMPLES:
    # Run agent-c5 tests
    $0 agent-c5
    
    # Run with clean build
    $0 --clean agent-c5
    
    # Run specific test
    $0 --test PulsarSingleNodeC5Tests agent-c5
    
    # Run all tests with verbose output
    $0 -v all
    
    # Run connector tests with custom Pulsar
    $0 -p apachepulsar/pulsar -t 3.0.0 connector

EOF
}

run_build() {
    if [ "$CLEAN_BUILD" = true ]; then
        print_header "Clean Building Project"
        ./gradlew clean build -x test
    else
        print_header "Building Project"
        ./gradlew build -x test
    fi
    print_success "Build completed"
    echo ""
}

run_tests() {
    local module=$1
    local test_class=$2
    
    print_header "Running Tests: $module"
    print_info "Pulsar Image: ${PULSAR_IMAGE}:${PULSAR_TAG}"
    print_info "This may take 15-30 minutes..."
    echo ""
    
    # Build Gradle command
    local gradle_cmd="./gradlew ${module}:test"
    gradle_cmd="$gradle_cmd -PtestPulsarImage=${PULSAR_IMAGE}"
    gradle_cmd="$gradle_cmd -PtestPulsarImageTag=${PULSAR_TAG}"
    
    if [ -n "$test_class" ]; then
        gradle_cmd="$gradle_cmd --tests \"$test_class\""
        print_info "Running specific test: $test_class"
    fi
    
    if [ "$VERBOSE" = true ]; then
        gradle_cmd="$gradle_cmd --info"
    fi
    
    if [ "$DEBUG" = true ]; then
        gradle_cmd="$gradle_cmd --debug"
    fi
    
    if [ "$INFO" = true ]; then
        gradle_cmd="$gradle_cmd --info"
    fi
    
    # Run tests
    local start_time=$(date +%s)
    
    if eval "$gradle_cmd"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_success "Tests passed in ${duration}s"
        local status=0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_error "Tests failed after ${duration}s"
        local status=1
    fi
    
    echo ""
    return $status
}

show_results() {
    local module=$1
    local report_path="${module}/build/reports/tests/test/index.html"
    
    print_header "Test Results"
    
    if [ -f "$report_path" ]; then
        print_info "Test report available at:"
        echo "  file://$(pwd)/${report_path}"
        echo ""
        
        # Show summary
        if [ -f "${module}/build/test-results/test/TEST-*.xml" ]; then
            local total=$(grep -h "tests=" ${module}/build/test-results/test/TEST-*.xml 2>/dev/null | head -1 | sed -E 's/.*tests="([0-9]+)".*/\1/')
            local failures=$(grep -h "failures=" ${module}/build/test-results/test/TEST-*.xml 2>/dev/null | head -1 | sed -E 's/.*failures="([0-9]+)".*/\1/')
            local errors=$(grep -h "errors=" ${module}/build/test-results/test/TEST-*.xml 2>/dev/null | head -1 | sed -E 's/.*errors="([0-9]+)".*/\1/')
            
            if [ -n "$total" ]; then
                echo "Test Summary:"
                echo "  Total Tests: $total"
                if [ "$failures" = "0" ] && [ "$errors" = "0" ]; then
                    print_success "All tests passed! ✨"
                else
                    echo "  Failures: $failures"
                    echo "  Errors: $errors"
                    print_error "Some tests failed"
                fi
                echo ""
            fi
        fi
        
        # Open report
        if [ "$OPEN_REPORT" = true ]; then
            print_info "Opening test report in browser..."
            open "$report_path" 2>/dev/null || xdg-open "$report_path" 2>/dev/null || echo "Please open manually: $report_path"
        fi
    else
        print_warning "Test report not found at $report_path"
    fi
}

show_docker_info() {
    print_info "Active containers during test:"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | head -10
    echo ""
}

###############################################################################
# Main Script
###############################################################################

# Parse arguments
TEST_TARGET="agent-c5"
TEST_CLASS=""
DEBUG=false
INFO=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--no-report)
            OPEN_REPORT=false
            shift
            ;;
        -p|--pulsar)
            PULSAR_IMAGE="$2"
            shift 2
            ;;
        -t|--tag)
            PULSAR_TAG="$2"
            shift 2
            ;;
        --test)
            TEST_CLASS="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --info)
            INFO=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        agent-c3|agent-c4|agent-c5|connector|all)
            TEST_TARGET="$1"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Print banner
echo ""
print_header "CDC Apache Cassandra Test Runner"
echo ""

# Check prerequisites
check_prerequisites

# Build project
run_build

# Run tests based on target
case $TEST_TARGET in
    agent-c3|agent-c4|agent-c5|connector)
        if run_tests "$TEST_TARGET" "$TEST_CLASS"; then
            show_results "$TEST_TARGET"
            exit 0
        else
            show_results "$TEST_TARGET"
            exit 1
        fi
        ;;
    all)
        print_header "Running All Tests"
        FAILED=0
        
        for module in agent-c3 agent-c4 agent-c5 connector; do
            if run_tests "$module" ""; then
                show_results "$module"
            else
                show_results "$module"
                FAILED=1
            fi
        done
        
        if [ $FAILED -eq 0 ]; then
            print_success "All test suites passed! 🎉"
            exit 0
        else
            print_error "Some test suites failed"
            exit 1
        fi
        ;;
    *)
        print_error "Unknown test target: $TEST_TARGET"
        show_usage
        exit 1
        ;;
esac
