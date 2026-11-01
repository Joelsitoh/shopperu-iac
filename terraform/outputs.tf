output "api_url" {
  description = "URL de la API de ShopPeru"
  value       = "${aws_apigatewayv2_stage.dev.invoke_url}/productos"
}

output "user_pool_id" {
  value = aws_cognito_user_pool.usuarios.id
}

output "lambda_catalogo" {
  value = aws_lambda_function.catalogo.function_name
}
