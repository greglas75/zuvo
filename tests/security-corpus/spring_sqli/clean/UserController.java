@RestController
public class UserController {
  @Autowired EntityManager em;
  // CLEAN: named parameter binding (no concatenation).
  @GetMapping("/users")
  public List find(@RequestParam String name) {
    return em.createQuery("SELECT u FROM User u WHERE u.name = :n").setParameter("n", name).getResultList();
  }
}
