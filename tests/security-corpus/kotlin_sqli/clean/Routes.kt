fun Route.users() {
  get("/users") {
    val name = call.parameters["name"]          // CLEAN: Exposed DSL bound parameter
    val rows = transaction { Users.select { Users.name eq name }.toList() }
    call.respond(rows)
  }
}
