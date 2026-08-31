fn main() -> Result<(), Box<dyn std::error::Error>> {
    let contract = pakperk_api::openapi::openapi_json_pretty()?;
    let output_paths = std::env::args_os().skip(1).collect::<Vec<_>>();
    if output_paths.is_empty() {
        print!("{contract}");
    } else {
        for output_path in output_paths {
            std::fs::write(output_path, &contract)?;
        }
    }
    Ok(())
}
