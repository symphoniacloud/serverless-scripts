#!/bin/bash

# Creates a Lambda and API Gateway proxying any verb on any path to lambda
#
# PREREQUISITES
#
# You must have the following installed locally: Java 8, mvn, AWS CLI
# Your AWS CLI must be configured for a user that has the necessary privileges
# You must have a basic role 'lambda_basic_execution' defined - this is what is created
# the first time you create a Lambda function in the web console
#
# USAGE
#
# make-java-api.sh -a API-NAME -l LAMBDA-NAME
#
# E.g., calling make-java-api.sh -a my-api -l MyHttpLambda
# This will:
# * Create a subdirectory named my-api, and create source files within it
# * Build and package a JAR file
# * Create a Lambda function within AWS named MyHttpLambda
# * Create an API Gateway API named my-api, which will call MyHttpLambda for any path

usage="Usage: make-java-api.sh -a API-NAME -l LAMBDA-NAME"

while [[ $# -gt 1 ]]
do
KEY="$1"

case $KEY in
    -a|--api-name)
    API_NAME="$2"
    shift # past argument
    ;;
    -l|--lambda-name)
    LAMBDA_FUNCTION_NAME="$2"
    shift # past argument
    ;;
    *)
            # unknown option
    ;;
esac
shift # past argument or value
done

if [[ -z "$API_NAME" ]]; then
    echo "API-NAME not set"
    echo "$usage"
    exit 1
fi
if [[ -z "$LAMBDA_FUNCTION_NAME" ]]; then
    echo "LAMBDA-NAME not set"
    echo "$usage"
    exit 1
fi

set -eu

echo "Creating new working directory $API_NAME"
if [[ -d "$API_NAME" ]]; then
	echo "API working directory already exists - aborting"
	exit 1
fi
mkdir "$API_NAME"
cd "$API_NAME"

# TODO - if doesn't exist, create it
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name lambda_basic_execution --query Role.Arn --output text)
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)
STAGE_NAME="api"

echo "Writing Java file src/main/java/yourpackage/HttpLambda.java"
mkdir -p src/main/java/yourpackage
cat > src/main/java/yourpackage/HttpLambda.java <<- EOM1
package yourpackage;

import com.amazonaws.services.lambda.runtime.Context;
import java.util.HashMap;
import java.util.Map;

public class HttpLambda {
    public Map<String, String> handler(Map m, Context context) {
        HashMap<String, String> response = new HashMap<>();
        response.put("statusCode", "200");
        response.put("body", "Hello World");
        return response;
    }
}
EOM1

echo "Creating Maven POM file"
cat > pom.xml <<- EOM2
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <groupId>yourpackage</groupId>
  <artifactId>http-lambda</artifactId>
  <version>1.0-SNAPSHOT</version>

  <properties>
    <maven.compiler.source>1.8</maven.compiler.source>
    <maven.compiler.target>1.8</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <dependencies>
    <dependency>
      <groupId>com.amazonaws</groupId>
      <artifactId>aws-lambda-java-core</artifactId>
      <version>1.1.0</version>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <artifactId>maven-shade-plugin</artifactId>
        <version>2.4.3</version>
        <executions>
          <execution>
            <phase>package</phase>
            <goals>
              <goal>shade</goal>
            </goals>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>
</project>
EOM2

echo "Compiling JAR file"
mvn package

echo "Creating Lambda function"
aws lambda create-function \
	--function-name "$LAMBDA_FUNCTION_NAME" \
	--runtime java8 \
	--role "$LAMBDA_ROLE_ARN" \
	--handler yourpackage.HttpLambda::handler \
	--zip-file fileb://target/http-lambda-1.0-SNAPSHOT.jar --memory-size 512

echo "Creating API $API_NAME..."
REST_API_ID=$(aws apigateway create-rest-api \
	--name "$API_NAME" \
	--query id --output text)
echo "API created with ID $REST_API_ID"

ROOT_RESOURCE_ID=$(aws apigateway get-resources \
	--rest-api-id "$REST_API_ID" \
	--query items[0].id --output text)
echo "Root resource ID $ROOT_RESOURCE_ID"

echo "Creating proxy resouce..."
PROXY_RESOURCE_ID=$(aws apigateway create-resource \
	--rest-api-id "$REST_API_ID" \
	--parent-id "$ROOT_RESOURCE_ID" \
	--path-part "{proxy+}" \
	--query id --output text)
echo "Proxy resource created with ID $PROXY_RESOURCE_ID"

setupApiMethod () {
	local RESOURCE_ID=$1
	local RESOURCE_DESCRIPTION=$2

	echo "Creating ANY method on $RESOURCE_DESCRIPTION resource..."
	aws apigateway put-method \
		--rest-api-id "$REST_API_ID" \
		--resource-id "$RESOURCE_ID" \
		--http-method ANY \
		--authorization-type NONE \
		--request-parameters method.request.path.proxy=true

	echo "Integrating $RESOURCE_DESCRIPTION resource with Lambda function '$LAMBDA_FUNCTION_NAME'..."
	aws apigateway put-integration \
		--rest-api-id "$REST_API_ID" \
		--resource-id "$RESOURCE_ID" \
		--http-method ANY \
		--integration-http-method POST \
		--type AWS_PROXY \
		--content-handling CONVERT_TO_TEXT \
		--cache-key-parameters "method.request.path.proxy" \
		--uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT:function:$LAMBDA_FUNCTION_NAME/invocations"

	echo "Completing $RESOURCE_DESCRIPTION resource integration by configuring method response..."
	# TODO - Not precisely the same as UI - that has null as opposed to "Empty" in response model
	aws apigateway put-method-response \
		--rest-api-id "$REST_API_ID" \
		--resource-id "$RESOURCE_ID" \
		--http-method ANY \
		--status-code 200 \
		--response-models "{\"application/json\": \"Empty\"}"	
}

setupApiMethod "$ROOT_RESOURCE_ID" "root"
setupApiMethod "$PROXY_RESOURCE_ID" "proxy"

echo "Deploying API to stage '$STAGE_NAME'..."
aws apigateway create-deployment \
	--rest-api-id "$REST_API_ID" \
	--stage-name "$STAGE_NAME"

echo "Updating Lambda to be executable by API..."
aws lambda add-permission \
	--function-name "$LAMBDA_FUNCTION_NAME" \
	--statement-id "api-$REST_API_ID-$ROOT_RESOURCE_ID" \
	--action lambda:InvokeFunction \
	--principal apigateway.amazonaws.com \
	--source-arn "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT:$REST_API_ID/*/*/*"

echo
echo "*** API Setup Complete!"
echo "API $API_NAME (ID $REST_API_ID) is available at https://$REST_API_ID.execute-api.$AWS_REGION.amazonaws.com/$STAGE_NAME"
echo "Try 'curl'ing it!"
echo