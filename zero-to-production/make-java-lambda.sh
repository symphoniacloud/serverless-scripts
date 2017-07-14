#!/bin/bash

# Creates a simple Java Lambda
#
# PREREQUISITES
#
# You must have the following installed locally: Java 8, mvn, AWS CLI
# Your AWS CLI must be configured for a user that has the necessary privileges
#
# USAGE
#
# make-java-lambda.sh -l LAMBDA-NAME
#
# E.g., calling make-java-lambda.sh -l MySimpleLambda
# This will:
# * Create a subdirectory named simple-lambda, and create source files within it
# * Build and package a JAR file
# * Create a Lambda function within AWS named MySimpleLambda

usage="Usage: make-java-lambda.sh -l LAMBDA-NAME"

while [[ $# -gt 1 ]]
do
KEY="$1"

case $KEY in
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

if [[ -z "$LAMBDA_FUNCTION_NAME" ]]; then
    echo "LAMBDA-NAME not set"
    echo "$usage"
    exit 1
fi

set -eu

echo "Creating new working directory simple-lambda"
if [[ -d "simple-lambda" ]]; then
	echo "Lambda working directory already exists - aborting"
	exit 1
fi
mkdir "simple-lambda"
cd "simple-lambda"

createBasicRole () {
  echo "lambda_basic_execution role didn't exist - creating it"
  cat > /tmp/temp-basic-role.json <<- EOM0
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            }
        }
    ]
}
EOM0

  ROLE_OUTPUT="$(aws iam create-role --role-name lambda_basic_execution --assume-role-policy-document file:///tmp/temp-basic-role.json)"

  rm /tmp/temp-basic-role.json

  # Otherwise role won't be ready when we create Lambda fn and we may see:
  # 'An error occurred (InvalidParameterValueException) when calling the CreateFunction operation: The role defined for the function cannot be assumed by Lambda.'
  # TODO - is there a less hacky way of doing
  sleep 10
}

# Check whether lambda_basic_execution role exists. If it doesn't, create it
if ! ROLE_OUTPUT="$(aws iam get-role --role-name lambda_basic_execution)" ; then
  createBasicRole
fi

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name lambda_basic_execution --query Role.Arn --output text)

echo "Writing Java file src/main/java/yourpackage/SimpleLambda.java"
mkdir -p src/main/java/yourpackage
cat > src/main/java/yourpackage/SimpleLambda.java <<- EOM1
package yourpackage;

public class SimpleLambda {
    public String handler(String input) {
        return "Hello, " + input;
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
  <artifactId>simple-lambda</artifactId>
  <version>1.0-SNAPSHOT</version>

  <properties>
    <maven.compiler.source>1.8</maven.compiler.source>
    <maven.compiler.target>1.8</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

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
	--handler yourpackage.SimpleLambda::handler \
	--zip-file fileb://target/simple-lambda-1.0-SNAPSHOT.jar --memory-size 256

echo
echo "*** Lambda Setup Complete!"
echo "To invoke your Lambda function from the CLI, execute:"
echo "$ aws lambda invoke --function-name $LAMBDA_FUNCTION_NAME --payload '\"world\"' output.txt"
echo "The return value from the function will be available in the file output.txt"
echo