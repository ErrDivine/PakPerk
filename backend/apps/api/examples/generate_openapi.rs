fn main() -> Result<(), Box<dyn std::error::Error>> {
    print!("{}", pakperk_api::openapi::openapi_json_pretty()?);
    Ok(())
}
