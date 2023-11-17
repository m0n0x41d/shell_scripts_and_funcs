
function get_openapi_diff() {
  if [[ "$#" -ne 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: get_openapi_diff specs/<file_name_1> specs/<file_name_2>"
    echo "Compares two OpenAPI specification files using openapi-diff."
    echo "Both YAML OpenAPI spec files should be specified with paths relative to ./specs."
    return 1
  fi

  if [[ ! -f "$1" || ! -f "$2" ]]; then
    echo "Error: One or both of the specified files do not exist."
    return 1
  fi

  docker run --rm -t \
      -v $(pwd)/specs:/specs:ro \
      openapitools/openapi-diff:latest /specs/$(basename "$1") /specs/$(basename "$2")

}